[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BackupPath,
  [switch]$ConfirmRestore
)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $root = Get-PilotRoot
  $backup = [IO.Path]::GetFullPath($BackupPath)
  $manifestPath = Join-Path $backup 'backup-manifest.json'
  $dumpPath = Join-Path $backup 'database.dump'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) { throw 'Выберите папку резервной копии с manifest и database.dump.' }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ([int]$manifest.schema_version -ne 1 -or -not $manifest.files) { throw 'Формат резервной копии не поддерживается. Данные не изменены.' }
  foreach ($requiredFile in @('database.dump', 'config/private.env', 'config/installation.json', 'license/public-key.pem')) {
    if (@($manifest.files) -cnotcontains $requiredFile) { throw "Manifest backup не содержит обязательный файл $requiredFile. Данные не изменены." }
  }
  $installation = Assert-PilotMachineBinding
  if ([string]$manifest.installation_id -cne [string]$installation.installation_id) { throw 'Резервная копия относится к другой установке. Данные не изменены.' }
  $backupInstallationPath = Join-Path $backup 'config\installation.json'
  if (-not (Test-Path -LiteralPath $backupInstallationPath -PathType Leaf)) { throw 'В резервной копии отсутствует привязка установки.' }
  $backupInstallation = Get-Content -LiteralPath $backupInstallationPath -Raw | ConvertFrom-Json
  if ([string]$backupInstallation.installation_id -cne [string]$installation.installation_id -or [string]$backupInstallation.machine_fingerprint -cne [string]$installation.machine_fingerprint) {
    throw 'Файл привязки внутри резервной копии повреждён или относится к другому компьютеру.'
  }
  $backupPublicKey = Join-Path $backup 'license\public-key.pem'
  $currentPublicKey = Join-Path $root 'license\public-key.pem'
  if (-not (Test-Path -LiteralPath $backupPublicKey -PathType Leaf) -or
      (Get-FileHash -LiteralPath $backupPublicKey -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $currentPublicKey -Algorithm SHA256).Hash) {
    throw 'Резервная копия использует другой ключ проверки лицензии. Данные не изменены.'
  }
  $currentEnv = Get-PilotEnvMap
  $backupEnvMap = @{}
  foreach ($line in Get-Content -LiteralPath (Join-Path $backup 'config\private.env')) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $backupEnvMap[$Matches[1]] = $Matches[2] }
  }
  $currentDatabase = Protect-PilotDatabaseName $currentEnv
  $backupDatabase = Protect-PilotDatabaseName $backupEnvMap
  if ($currentDatabase.Name -cne $backupDatabase.Name -or $currentDatabase.User -cne $backupDatabase.User -or
      (Get-PilotEnvValue $currentEnv 'COMPOSE_PROJECT_NAME' '') -cne (Get-PilotEnvValue $backupEnvMap 'COMPOSE_PROJECT_NAME' '') -or
      [string]$manifest.database -cne $currentDatabase.Name) {
    throw 'Резервная копия имеет несовместимые параметры установки или базы данных. Данные не изменены.'
  }
  $actualHash = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne [string]$manifest.database_sha256) { throw 'Контрольная сумма дампа не совпала. Данные не изменены.' }
  $storageBackup = Join-Path $backup 'server-storage'
  $storageEntries = @($manifest.storage_files)
  $validatedStorageFiles = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in $storageEntries) {
    $relative = ([string]$entry.path).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or (($relative -split '/') -contains '..') -or $relative -match '(^|/)[^/]*:') { throw 'Manifest содержит небезопасный путь к файлу. Данные не изменены.' }
    $storageFile = [IO.Path]::GetFullPath((Join-Path $storageBackup ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $storagePrefix = [IO.Path]::GetFullPath($storageBackup).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $storageFile.StartsWith($storagePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $storageFile -PathType Leaf)) { throw 'Файл постоянного хранилища из backup отсутствует или находится вне папки backup.' }
    $cursor = $storageFile
    while ($cursor.StartsWith($storagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      $cursorItem = Get-Item -LiteralPath $cursor -Force
      if (($cursorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Backup содержит ссылку в persistent storage. Восстановление остановлено.' }
      $cursor = Split-Path -Parent $cursor
    }
    if ((Get-Item -LiteralPath $storageFile).Length -ne [long]$entry.size_bytes -or (Get-FileHash -LiteralPath $storageFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) { throw "Файл хранилища $relative повреждён; данные не изменены." }
    $validatedStorageFiles.Add([pscustomobject]@{ Relative = $relative; Source = $storageFile })
  }
  if (-not $ConfirmRestore) { Write-Host "Будет восстановлена база из $($manifest.created_at). Перед этим создайте/проверьте резервную копию; требуется -ConfirmRestore."; exit 2 }
  $answer = Read-Host 'Для продолжения введите ВОССТАНОВИТЬ MAHABBAT'
  if ($answer -cne 'ВОССТАНОВИТЬ MAHABBAT') { Write-Host 'Восстановление отменено.'; exit 2 }

  $container = Get-PilotServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($container)) { throw 'PostgreSQL не запущен. Сначала запустите start.ps1.' }
  $probeDump = "/tmp/mahabbat-restore-check-$([Guid]::NewGuid().ToString('N')).dump"
  & docker.exe cp $dumpPath "${container}:$probeDump"
  if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить дамп на целевом runtime. Текущая БД не изменена.' }
  & docker.exe exec $container pg_restore --list $probeDump *> $null
  $probeExit = $LASTEXITCODE
  & docker.exe exec $container rm -f $probeDump 2>$null | Out-Null
  if ($probeExit -ne 0) { throw 'Дамп не прошёл проверку pg_restore. Текущая БД не изменена.' }

  $storageStage = Join-Path (Join-Path $root '.private') ('restore-storage-' + [Guid]::NewGuid().ToString('N'))
  if ($storageEntries.Count -gt 0 -and -not (Test-Path -LiteralPath $storageBackup -PathType Container)) {
    throw 'В backup отсутствует папка постоянного хранилища.'
  }
  New-Item -ItemType Directory -Force -Path $storageStage | Out-Null
  foreach ($file in $validatedStorageFiles) {
    $destination = Join-Path $storageStage ($file.Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.Source -Destination $destination
  }

  $rollback = New-PilotDatabaseBackup
  $envMap = Get-PilotEnvMap
  $database = Protect-PilotDatabaseName $envMap
  $container = Get-PilotServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($container)) { throw "PostgreSQL остановлен. Предварительная копия: $rollback" }
  Stop-PilotPrintGateway
  Invoke-PilotCompose @('stop', 'server', 'worker', 'pos-gateway', 'license-gateway')
  $containerDump = '/tmp/mahabbat-restore.dump'
  & docker.exe cp $dumpPath "${container}:$containerDump"
  if ($LASTEXITCODE -ne 0) { throw "Не удалось скопировать дамп. Текущая БД сохранена; rollback: $rollback" }
  & docker.exe exec $container pg_restore --clean --if-exists --exit-on-error --no-owner --no-acl -U $database.User -d $database.Name $containerDump
  $restoreExit = $LASTEXITCODE
  & docker.exe exec $container rm -f $containerDump 2>$null | Out-Null
  if ($restoreExit -ne 0) { throw "Восстановление не завершено. Приложение оставлено остановленным; rollback: $rollback" }

  $liveStorage = Join-Path $root 'data\server-storage'
  $oldStorage = Join-Path $rollback 'restore-old-server-storage'
  if (Test-Path -LiteralPath $liveStorage -PathType Container) { Move-Item -LiteralPath $liveStorage -Destination $oldStorage }
  if (Test-Path -LiteralPath $storageStage -PathType Container) { Move-Item -LiteralPath $storageStage -Destination $liveStorage }
  else { New-Item -ItemType Directory -Force -Path $liveStorage | Out-Null }

  $envBackup = Join-Path $backup 'config\private.env'
  if (Test-Path -LiteralPath $envBackup -PathType Leaf) { Copy-Item -LiteralPath $envBackup -Destination (Join-Path $root '.env') -Force; Protect-PilotPrivatePath -Path (Join-Path $root '.env') }
  $licenseBackup = Join-Path $backup 'license\license.json'
  $licenseCurrent = Join-Path $root 'license\license.json'
  if (Test-Path -LiteralPath $licenseBackup -PathType Leaf) { Copy-Item -LiteralPath $licenseBackup -Destination $licenseCurrent -Force }
  Invoke-PilotCompose @('up', '-d')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw "База восстановлена, но запуск не завершился; выполните status.ps1. Предварительный rollback: $rollback" }
  Start-PilotPrintGateway
  if (Test-Path -LiteralPath $oldStorage -PathType Container) { Remove-Item -LiteralPath $oldStorage -Recurse -Force }
  Write-Host "Восстановление завершено. Предварительная резервная копия: $rollback"
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
