[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ReleaseArchive,
  [switch]$ConfirmUpdate
)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  Assert-PilotMachineBinding | Out-Null
  Assert-PilotDocker
  $root = Get-PilotRoot
  $archive = [IO.Path]::GetFullPath($ReleaseArchive)
  if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Архив обновления не найден.' }
  if ([IO.Path]::GetExtension($archive) -ne '.zip') { throw 'Ожидается ZIP-архив релиза Mahabbat.' }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $seenEntries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
      $rawName = [string]$entry.FullName
      $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
      if ($rawName.Contains('\') -or $rawName.StartsWith('/') -or [IO.Path]::IsPathRooted($rawName) -or $rawName -match '^[A-Za-z]:' -or $unixMode -eq 0xA000) { throw 'Архив содержит небезопасный путь; обновление отменено.' }
      $name = $rawName.TrimStart('/')
      $segments = @($name.TrimEnd('/') -split '/')
      if ($segments -contains '..' -or $segments -contains '.') { throw 'Архив содержит небезопасный путь; обновление отменено.' }
      if (@($segments | Where-Object { $_.Contains(':') -or $_ -match '[ .]$' -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)' }).Count -gt 0) { throw 'Архив содержит имя файла, несовместимое с безопасной установкой Windows.' }
      if (-not $seenEntries.Add($name)) { throw 'В архиве есть повторяющиеся пути; обновление отменено.' }
      if (@($segments | Where-Object { $_ -in @('.git', '.private', 'node_modules', 'data', 'backups') -or $_ -match '^\.env($|\.)' }).Count -gt 0 -or
          $name -match '(^|/)license/license\.json$|(^|/)config/installation\.json$|(^|/)config/private\.env$|(^|/)id_(rsa|ed25519)(\.|$)|license-signing-ed25519|\.(key|token|pdb|ts|tsx|map)$' -or
          ($name -match '\.pem$' -and $name -cne 'license/public-key.pem')) {
        throw 'Архив обновления содержит пользовательские данные, исходники или секреты; обновление отменено.'
      }
    }
  } finally { $zip.Dispose() }

  $stage = Join-Path (Join-Path $root '.private') ('update-stage-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Protect-PilotPrivatePath -Path $stage -Directory
  try {
    Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
    $releaseVersion = (Get-Content -LiteralPath (Join-Path $stage 'VERSION') -Raw).Trim()
    $currentVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
    $newSemver = [version]($releaseVersion -replace '^v', '')
    $oldSemver = [version]($currentVersion -replace '^v', '')
    if ($newSemver -le $oldSemver) { throw "Версия обновления $releaseVersion должна быть выше текущей $currentVersion." }
    $newPublicKey = Join-Path $stage 'license\public-key.pem'
    $currentPublicKey = Join-Path $root 'license\public-key.pem'
    if (-not (Test-Path -LiteralPath $newPublicKey) -or
        (Get-FileHash $newPublicKey -Algorithm SHA256).Hash -cne (Get-FileHash $currentPublicKey -Algorithm SHA256).Hash) {
      throw 'Ключ проверки лицензии отличается. Требуется отдельная безопасная процедура перехода ключа.'
    }
    foreach ($required in @('compose.yaml', 'runtime-images.tar', 'image-manifest.json', ("app\mahabbat-{0}.tgz" -f $releaseVersion), 'release-manifest.json')) {
      if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Архив неполон: отсутствует $required." }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $stage 'release-manifest.json') -Raw | ConvertFrom-Json
    if ([int]$manifest.schema_version -ne 1 -or [string]$manifest.version -cne $releaseVersion -or [string]$manifest.product -cne 'Mahabbat') { throw 'Версия или схема в release manifest не совпадает с архивом.' }
    if ([string]$manifest.image_archive_sha256 -cne (Get-FileHash -LiteralPath (Join-Path $stage 'runtime-images.tar') -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Архив контейнеров повреждён; обновление отменено.' }
    $manifestPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($manifest.files)) {
      $relative = ([string]$file.path).Replace('\', '/')
      if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or (($relative -split '/') -contains '..') -or -not $manifestPaths.Add($relative)) { throw 'Release manifest содержит небезопасный или повторяющийся путь.' }
      $payloadPath = [IO.Path]::GetFullPath((Join-Path $stage ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
      $stagePrefix = [IO.Path]::GetFullPath($stage).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
      if (-not $payloadPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw "Release manifest ссылается на отсутствующий файл: $relative" }
      if ((Get-Item -LiteralPath $payloadPath).Length -ne [long]$file.size_bytes -or (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.sha256) { throw "Контрольная сумма файла $relative не совпала; обновление отменено." }
    }
    $actualPayloadCount = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object { $_.FullName -cne (Join-Path $stage 'release-manifest.json') }).Count
    if ($actualPayloadCount -ne $manifestPaths.Count) { throw 'Архив содержит файлы, которых нет в release manifest.' }
    $answer = Read-Host "Перед обновлением будет создана резервная копия. Введите ОБНОВИТЬ MAHABBAT $releaseVersion"
    if ($answer -cne "ОБНОВИТЬ MAHABBAT $releaseVersion") { Write-Host 'Обновление отменено.'; exit 2 }

    $rollback = New-PilotDatabaseBackup
    Stop-PilotPrintGateway
    Invoke-PilotCompose @('stop', 'server', 'worker', 'pos-gateway', 'license-gateway')
    $managedFiles = @('compose.yaml', 'VERSION', 'image-manifest.json', 'runtime-images.tar', 'README.txt', 'release-manifest.json')
    foreach ($file in $managedFiles) { Copy-Item -LiteralPath (Join-Path $stage $file) -Destination (Join-Path $root $file) -Force }
    foreach ($directory in @('app', 'runtime', 'licenses')) {
      $sourceDirectory = Join-Path $stage $directory
      if (Test-Path -LiteralPath $sourceDirectory) {
        $destinationDirectory = Join-Path $root $directory
        if (Test-Path -LiteralPath $destinationDirectory) { Remove-Item -LiteralPath $destinationDirectory -Recurse -Force }
        Copy-Item -LiteralPath $sourceDirectory -Destination $destinationDirectory -Recurse
      }
    }
    foreach ($file in @('install.ps1', 'install-app.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'backup.ps1', 'restore.ps1', 'update.ps1', 'activation-request.ps1', 'activate.ps1', 'doctor.ps1')) {
      Copy-Item -LiteralPath (Join-Path $stage $file) -Destination (Join-Path $root $file) -Force
    }
    $sourceScripts = Join-Path $stage 'scripts\pilot-common.ps1'
    Copy-Item -LiteralPath $sourceScripts -Destination (Join-Path $root 'scripts\pilot-common.ps1') -Force
    & docker.exe load --input (Join-Path $root 'runtime-images.tar')
    if ($LASTEXITCODE -ne 0) { throw "Образы не загрузились; перед обновлением создана резервная копия: $rollback" }
    Invoke-PilotCompose @('config', '--quiet')
    Invoke-PilotCompose @('up', '-d')
    if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw "Новый runtime не готов. Данные сохранены; резервная копия: $rollback" }
    Start-PilotPrintGateway
    Write-Host "Обновление до $releaseVersion завершено. База, лицензия и локальная конфигурация сохранены."
    Write-Host "Предварительная резервная копия: $rollback"
  } finally {
    if (Test-Path -LiteralPath $stage) {
      $resolvedStage = [IO.Path]::GetFullPath($stage)
      $privateRoot = [IO.Path]::GetFullPath((Join-Path $root '.private')) + [IO.Path]::DirectorySeparatorChar
      if (-not $resolvedStage.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Небезопасный путь временной очистки.' }
      Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
