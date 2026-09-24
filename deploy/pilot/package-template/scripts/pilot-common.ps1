Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PilotRoot {
  return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-PilotEnvMap {
  $path = Join-Path (Get-PilotRoot) '.env'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Локальная конфигурация ещё не создана. Запустите install.ps1.' }
  $map = @{}
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
  }
  return $map
}

function Get-PilotEnvValue {
  param([hashtable]$Map, [Parameter(Mandatory = $true)][string]$Name, [string]$Default = '')
  if ($Map.ContainsKey($Name)) { return [string]$Map[$Name] }
  return $Default
}

function Get-PilotComposeProjectName {
  $envMap = Get-PilotEnvMap
  $project = Get-PilotEnvValue $envMap 'COMPOSE_PROJECT_NAME' 'mahabbat-pilot'
  if ($project -notmatch '^[a-z0-9][a-z0-9_-]{0,62}$') { throw 'Имя локального проекта содержит недопустимые символы.' }
  return $project
}

function New-PilotRandomHex {
  param([ValidateRange(16, 128)][int]$ByteCount = 32)
  $bytes = New-Object byte[] $ByteCount
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return ([BitConverter]::ToString($bytes).Replace('-', '')).ToLowerInvariant()
}

function Get-PilotMachineFingerprint {
  try {
    $machineGuid = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid)
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    $systemUuid = [string]$product.UUID
  } catch {
    throw 'Не удалось получить стабильный идентификатор компьютера. Запустите установку от имени администратора или проверьте доступ к системным сведениям Windows.'
  }
  if ([string]::IsNullOrWhiteSpace($machineGuid) -or [string]::IsNullOrWhiteSpace($systemUuid) -or $systemUuid -match '^0{8}-0{4}-0{4}-0{4}-0{12}$') {
    throw 'Windows не предоставила стабильные идентификаторы оборудования; активационный запрос не создан.'
  }
  $material = "mahabbat-pilot-v1`n$($machineGuid.Trim().ToLowerInvariant())`n$($systemUuid.Trim().ToLowerInvariant())"
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))).Replace('-', '')).ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-PilotInstallation {
  $path = Join-Path (Get-PilotRoot) 'config\installation.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
  catch { throw 'Файл привязки установки повреждён. Не удаляйте данные; обратитесь к сопровождающему.' }
}

function Assert-PilotMachineBinding {
  $installation = Get-PilotInstallation
  if ($null -eq $installation) { throw 'Привязка установки отсутствует. Запустите install.ps1.' }
  $actual = Get-PilotMachineFingerprint
  if ($actual -cne [string]$installation.machine_fingerprint) {
    throw 'Эта установка привязана к другому компьютеру. База данных не изменена; для переноса запросите новую лицензию.'
  }
  return $installation
}

function Protect-PilotPrivatePath {
  param([Parameter(Mandatory = $true)][string]$Path, [switch]$Directory)
  $resolved = [IO.Path]::GetFullPath($Path)
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($Directory) {
    $userGrant = "*$($sid):(OI)(CI)F"
    $systemGrant = '*S-1-5-18:(OI)(CI)F'
    $adminsGrant = '*S-1-5-32-544:(OI)(CI)F'
  } else {
    $userGrant = "*$($sid):(R,W)"
    $systemGrant = '*S-1-5-18:(R)'
    $adminsGrant = '*S-1-5-32-544:(R)'
  }
  & icacls.exe $resolved /inheritance:r /grant:r $userGrant $systemGrant $adminsGrant *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Не удалось ограничить доступ к локальному секрету средствами Windows.' }
}

function Assert-PilotDocker {
  if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) { throw 'Docker Desktop не найден. Установите Docker Desktop и повторно запустите Mahabbat.' }
  $null = & docker.exe version --format '{{.Server.Version}}' 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop установлен, но ещё не готов. Запустите Docker Desktop и дождитесь статуса «Engine running».' }
  $null = & docker.exe compose version 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'В Docker Desktop недоступен Compose. Обновите Docker Desktop до поддерживаемой версии.' }
}

function Start-PilotDockerDesktop {
  try { Assert-PilotDocker; return } catch { }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\Docker Desktop.exe')
  )
  $desktop = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $desktop) { throw 'Docker Desktop не установлен. Установите его один раз, затем повторно запустите install.ps1.' }
  Start-Process -FilePath $desktop -WindowStyle Hidden | Out-Null
  $deadline = (Get-Date).AddMinutes(5)
  do {
    try { Assert-PilotDocker; return } catch { Start-Sleep -Seconds 3 }
  } while ((Get-Date) -lt $deadline)
  throw 'Docker Desktop не запустился за 5 минут. Проверьте виртуализацию и повторите запуск.'
}

function Get-PilotUrlMap {
  $envMap = Get-PilotEnvMap
  return @{
    Crm = 'http://127.0.0.1:{0}' -f (Get-PilotEnvValue $envMap 'CRM_PORT' '3000')
    Pos = 'http://127.0.0.1:{0}' -f (Get-PilotEnvValue $envMap 'POS_PORT' '3100')
    LicenseStatus = 'http://127.0.0.1:{0}/status' -f (Get-PilotEnvValue $envMap 'LICENSE_STATUS_PORT' '3199')
    PrintHealth = 'http://127.0.0.1:{0}/health' -f (Get-PilotEnvValue $envMap 'PRINT_GATEWAY_PORT' '3110')
  }
}

function Invoke-PilotCompose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $root = Get-PilotRoot
  $project = Get-PilotComposeProjectName
  $composeArgs = @(
    'compose', '--project-name', $project, '--project-directory', $root,
    '--file', (Join-Path $root 'compose.yaml'), '--env-file', (Join-Path $root '.env')
  ) + $Arguments
  & docker.exe @composeArgs
  if ($LASTEXITCODE -ne 0) { throw "Docker Compose завершился с кодом $LASTEXITCODE." }
}

function Get-PilotServiceContainerId {
  param([Parameter(Mandatory = $true)][string]$Service)
  $root = Get-PilotRoot
  $project = Get-PilotComposeProjectName
  $composeArgs = @('compose', '--project-name', $project, '--project-directory', $root, '--file', (Join-Path $root 'compose.yaml'), '--env-file', (Join-Path $root '.env'), 'ps', '-q', $Service)
  $id = (& docker.exe @composeArgs 2>$null | Select-Object -First 1)
  if ($LASTEXITCODE -ne 0) { return '' }
  return ([string]$id).Trim()
}

function Get-PilotRunningServiceSnapshot {
  param([Parameter(Mandatory = $true)][string[]]$Services)
  $root = Get-PilotRoot
  $project = Get-PilotComposeProjectName
  $composeArgs = @('compose', '--project-name', $project, '--project-directory', $root, '--file', (Join-Path $root 'compose.yaml'), '--env-file', (Join-Path $root '.env'), 'ps', '--all', '-q')
  $snapshot = [System.Collections.Generic.List[object]]::new()
  foreach ($service in $Services) {
    $ids = @(& docker.exe @composeArgs $service 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    foreach ($id in $ids) {
      $containerId = ([string]$id).Trim()
      $running = (& docker.exe inspect --format '{{.State.Running}}' $containerId 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -eq 0 -and ([string]$running).Trim() -eq 'true') {
        $snapshot.Add([pscustomobject]@{ Service = $service; ContainerId = $containerId })
      }
    }
  }
  return @($snapshot)
}

function Wait-PilotContainerSnapshot {
  param([Parameter(Mandatory = $true)][object[]]$Snapshot, [ValidateRange(1, 900)][int]$TimeoutSeconds = 600)
  if ($Snapshot.Count -eq 0) { return $true }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $allReady = $true
    foreach ($entry in $Snapshot) {
      $health = (& docker.exe inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' ([string]$entry.ContainerId) 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -ne 0 -or ([string]$health).Trim() -notin @('healthy', 'running')) { $allReady = $false; break }
    }
    if ($allReady) { return $true }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Protect-PilotDatabaseName {
  param([hashtable]$Map)
  $name = Get-PilotEnvValue $Map 'PG_DATABASE_NAME' 'mahabbat'
  $user = Get-PilotEnvValue $Map 'PG_DATABASE_USER' 'mahabbat'
  if ($name -notmatch '^[A-Za-z0-9_]+$' -or $user -notmatch '^[A-Za-z0-9_]+$') { throw 'Имя базы или пользователя содержит недопустимые символы.' }
  return @{ Name = $name; User = $user }
}

function Copy-PilotPersistentStorage {
  param([Parameter(Mandatory = $true)][string]$SourceRoot, [Parameter(Mandatory = $true)][string]$DestinationRoot)
  $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $source -PathType Container)) { return @() }
  $destination = [IO.Path]::GetFullPath($DestinationRoot)
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  $pending = [System.Collections.Generic.Stack[string]]::new()
  $pending.Push($source)
  $files = [System.Collections.Generic.List[object]]::new()
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Persistent storage contains a link/reparse point; backup stopped rather than reading outside the installation.'
      }
      $relative = $item.FullName.Substring($source.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
      $target = Join-Path $destination $relative
      if ($item.PSIsContainer) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $pending.Push($item.FullName)
      } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $target
        $files.Add([ordered]@{
          path = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
          size_bytes = [long](Get-Item -LiteralPath $target).Length
          sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        })
      }
    }
  }
  return @($files)
}

function New-PilotDatabaseBackup {
  $root = Get-PilotRoot
  Assert-PilotDocker
  Assert-PilotMachineBinding | Out-Null
  $envMap = Get-PilotEnvMap
  $database = Protect-PilotDatabaseName $envMap
  $container = Get-PilotServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($container)) { throw 'PostgreSQL не запущен. Сначала запустите start.ps1.' }
  $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss-fff'
  $backupDir = Join-Path (Join-Path $root 'backups') $stamp
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  Protect-PilotPrivatePath -Path $backupDir -Directory
  $containerDump = "/tmp/mahabbat-$stamp-$([Guid]::NewGuid().ToString('N')).dump"
  $writeServices = @('server', 'worker', 'pos-gateway', 'license-gateway')
  $runningSnapshot = @(Get-PilotRunningServiceSnapshot -Services $writeServices)
  $printWasRunning = $null -ne (Get-PilotPrintGatewayProcess)
  $snapshotStopped = $false
  Write-Host 'Для согласованной копии запись временно приостанавливается; база и файлы не удаляются.'
  try {
    if ($printWasRunning) { Stop-PilotPrintGateway }
    $snapshotStopped = $true
    if ($runningSnapshot.Count -gt 0) {
      $runningNames = @($runningSnapshot | Select-Object -ExpandProperty Service -Unique)
      Invoke-PilotCompose (@('stop') + $runningNames)
    }
    & docker.exe exec $container sh -c "pg_dump -U '$($database.User)' -d '$($database.Name)' -Fc --no-owner --no-acl > '$containerDump'"
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать резервную копию базы данных.' }
    $dumpPath = Join-Path $backupDir 'database.dump'
    & docker.exe cp "${container}:$containerDump" $dumpPath
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось сохранить резервную копию базы на компьютере.' }
    & docker.exe exec $container pg_restore --list $containerDump *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Проверка созданного дампа не прошла.' }
    $storageSource = Join-Path $root 'data\server-storage'
    $storageFiles = Copy-PilotPersistentStorage -SourceRoot $storageSource -DestinationRoot (Join-Path $backupDir 'server-storage')
  } finally {
    & docker.exe exec $container rm -f $containerDump 2>$null | Out-Null
    if ($snapshotStopped) {
      foreach ($service in @('server', 'worker', 'pos-gateway', 'license-gateway')) {
        foreach ($entry in @($runningSnapshot | Where-Object { $_.Service -eq $service })) {
          & docker.exe start ([string]$entry.ContainerId) *> $null
          if ($LASTEXITCODE -ne 0) { throw "Не удалось вернуть службу $service после резервного снимка." }
        }
      }
      if (-not (Wait-PilotContainerSnapshot -Snapshot $runningSnapshot -TimeoutSeconds 600)) {
        throw 'Резервный снимок создан, но исходные службы не вернулись в рабочее состояние. Проверьте status.ps1.'
      }
      if ($printWasRunning) { Start-PilotPrintGateway }
    }
  }

  $files = @(
    @{ Source = Join-Path $root '.env'; Relative = 'config\private.env' },
    @{ Source = Join-Path $root 'config\installation.json'; Relative = 'config\installation.json' },
    @{ Source = Join-Path $root 'compose.yaml'; Relative = 'config\compose.yaml' },
    @{ Source = Join-Path $root 'VERSION'; Relative = 'config\VERSION' },
    @{ Source = Join-Path $root 'license\public-key.pem'; Relative = 'license\public-key.pem' }
  )
  foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) { throw "Нельзя завершить резервную копию: отсутствует $($file.Relative)." }
    $destination = Join-Path $backupDir $file.Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.Source -Destination $destination
  }
  $licensePath = Join-Path $root 'license\license.json'
  if (Test-Path -LiteralPath $licensePath -PathType Leaf) { Copy-Item -LiteralPath $licensePath -Destination (Join-Path $backupDir 'license\license.json') }
  $installation = Get-PilotInstallation
  $manifest = [ordered]@{
    schema_version = 1
    created_at = [DateTime]::UtcNow.ToString('o')
    version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
    installation_id = [string]$installation.installation_id
    database = $database.Name
    files = @('database.dump', 'config/private.env', 'config/installation.json', 'config/compose.yaml', 'config/VERSION', 'license/public-key.pem', 'server-storage/')
    storage_files = @($storageFiles)
    database_sha256 = (Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash.ToLowerInvariant()
    restore = 'Run restore.ps1 -BackupPath <folder> -ConfirmRestore; verify CRM, POS, license status, and reconciliation afterward.'
  }
  if (Test-Path -LiteralPath $licensePath -PathType Leaf) { $manifest.files += 'license/license.json' }
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
  Write-Host "Резервная копия создана и проверена: $backupDir"
  return $backupDir
}

function Test-PilotUrl {
  param([Parameter(Mandatory = $true)][string]$Url, [int[]]$ExpectedStatus = @(200))
  try {
    $response = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec 3
    return ($ExpectedStatus -contains [int]$response.StatusCode)
  } catch {
    $status = 0
    $responseProperty = $_.Exception.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
      $status = [int]$responseProperty.Value.StatusCode
    }
    return ($ExpectedStatus -contains $status)
  }
}

function Test-PilotPortAvailable {
  param([Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port)
  $listener = $null
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    return $true
  } catch { return $false }
  finally { if ($listener) { $listener.Stop() } }
}

function Get-PilotLicenseStatus {
  try {
    $urls = Get-PilotUrlMap
    return (Invoke-RestMethod -Uri $urls.LicenseStatus -Method Get -TimeoutSec 3)
  } catch { return [pscustomobject]@{ status = 'UNAVAILABLE'; active = $false } }
}

function Wait-PilotRuntime {
  param([ValidateRange(1, 900)][int]$TimeoutSeconds = 360)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $urls = Get-PilotUrlMap
  do {
    if ((Test-PilotUrl ($urls.Crm + '/healthz')) -and
        (Test-PilotUrl ($urls.Pos + '/health')) -and
        (Test-PilotUrl $urls.LicenseStatus)) { return $true }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Get-PilotPrintGatewayProcess {
  $pidPath = Join-Path (Get-PilotRoot) '.private\print-gateway.pid'
  if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $null }
  try { $processId = [int](Get-Content -LiteralPath $pidPath -Raw).Trim() } catch { return $null }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if ($null -eq $process -or $process.Name -ne 'node.exe' -or $process.CommandLine -notmatch 'print-gateway\.mjs') { return $null }
  return (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

function Start-PilotPrintGateway {
  $urls = Get-PilotUrlMap
  if (Test-PilotUrl $urls.PrintHealth) { return }
  if ($null -ne (Get-PilotPrintGatewayProcess)) { throw 'Служба печати запущена, но не отвечает. Запустите doctor.ps1.' }
  $root = Get-PilotRoot
  $node = Join-Path $root 'runtime\node\node.exe'
  $entry = Join-Path $root 'runtime\print-gateway\print-gateway.mjs'
  if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw 'В релизном пакете отсутствуют необходимые компоненты службы печати.'
  }
  $envMap = Get-PilotEnvMap
  $names = @('TWENTY_API_URL', 'MAHABBAT_INTERNAL_ROUTE_SECRET', 'PRINT_GATEWAY_MODE', 'PRINT_GATEWAY_HOST', 'PRINT_GATEWAY_PORT')
  $previous = @{}
  foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
  $logDir = Join-Path $root 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  foreach ($logName in @('print-gateway.out.log', 'print-gateway.err.log')) {
    $logPath = Join-Path $logDir $logName
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 2MB) {
      $rotated = "$logPath.1"
      if (Test-Path -LiteralPath $rotated) { Remove-Item -LiteralPath $rotated -Force }
      Move-Item -LiteralPath $logPath -Destination $rotated
    }
  }
  try {
    $env:TWENTY_API_URL = $urls.Crm
    $env:MAHABBAT_INTERNAL_ROUTE_SECRET = Get-PilotEnvValue $envMap 'MAHABBAT_INTERNAL_ROUTE_SECRET'
    $env:PRINT_GATEWAY_MODE = 'LOCAL'
    $env:PRINT_GATEWAY_HOST = '0.0.0.0'
    $env:PRINT_GATEWAY_PORT = Get-PilotEnvValue $envMap 'PRINT_GATEWAY_PORT' '3110'
    $entryArg = '"{0}"' -f $entry
    $process = Start-Process -FilePath $node -ArgumentList $entryArg -WorkingDirectory (Split-Path -Parent $entry) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir 'print-gateway.out.log') -RedirectStandardError (Join-Path $logDir 'print-gateway.err.log') -PassThru
    $privateDir = Join-Path $root '.private'
    New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
    Protect-PilotPrivatePath -Path $privateDir -Directory
    [IO.File]::WriteAllText((Join-Path $privateDir 'print-gateway.pid'), [string]$process.Id, [Text.UTF8Encoding]::new($false))
  } finally {
    foreach ($name in $names) {
      if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
      else { Set-Item -LiteralPath "Env:$name" -Value $previous[$name] }
    }
  }
  $deadline = (Get-Date).AddSeconds(30)
  do {
    if (Test-PilotUrl $urls.PrintHealth) { return }
    if ($process.HasExited) { throw 'Служба печати не запустилась. Откройте doctor.ps1 для диагностики.' }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  throw 'Служба печати не ответила за 30 секунд.'
}

function Stop-PilotPrintGateway {
  $process = Get-PilotPrintGatewayProcess
  if ($null -ne $process) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
  $pidPath = Join-Path (Get-PilotRoot) '.private\print-gateway.pid'
  if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue }
}

function Set-PilotPrivateFile {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
  Protect-PilotPrivatePath -Path $Path
}

function Set-PilotEnvValues {
  param([Parameter(Mandatory = $true)][hashtable]$Values)
  $path = Join-Path (Get-PilotRoot) '.env'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Локальная конфигурация ещё не создана.' }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $path) { $lines.Add([string]$line) }
  foreach ($name in $Values.Keys) {
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Недопустимое имя параметра конфигурации.' }
    $escaped = [regex]::Escape([string]$name)
    $matched = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
      if ($lines[$index] -match "^\s*$escaped=") {
        $lines[$index] = "${name}=$([string]$Values[$name])"
        $matched = $true
        break
      }
    }
    if (-not $matched) { $lines.Add("${name}=$([string]$Values[$name])") }
  }
  [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
  Protect-PilotPrivatePath -Path $path
}
