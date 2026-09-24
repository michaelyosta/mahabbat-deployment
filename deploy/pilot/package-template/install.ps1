[CmdletBinding()]
param(
  [ValidateRange(1, 65535)][int]$CrmPort = 3000,
  [ValidateRange(1, 65535)][int]$PosPort = 3100,
  [ValidateRange(1, 65535)][int]$LicenseStatusPort = 3199,
  [ValidateRange(1, 65535)][int]$PrintGatewayPort = 3110
)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $root = Get-PilotRoot
  if ((@($CrmPort, $PosPort, $LicenseStatusPort, $PrintGatewayPort) | Select-Object -Unique | Measure-Object).Count -ne 4) { throw 'Порты CRM/POS/служб должны быть различными.' }
  foreach ($path in @('compose.yaml', 'runtime-images.tar', 'license\public-key.pem', 'image-manifest.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) { throw "В пакете отсутствует обязательный файл: $path" }
  }

  $dataPath = Join-Path $root 'data\postgres'
  $configPath = Join-Path $root 'config\installation.json'
  $envPath = Join-Path $root '.env'
  $hasPersistentData = $false
  foreach ($relative in @('data\postgres', 'data\redis', 'data\server-storage', 'data\license-state')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Container) {
      $firstEntry = Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First 1
      if ($null -ne $firstEntry) { $hasPersistentData = $true; break }
    }
  }
  if ($hasPersistentData -and ((-not (Test-Path -LiteralPath $configPath -PathType Leaf)) -or (-not (Test-Path -LiteralPath $envPath -PathType Leaf)))) {
    throw 'Обнаружены данные без конфигурации установки. Ничего не перезаписано; обратитесь к сопровождающему.'
  }
  if ((Test-Path -LiteralPath $envPath -PathType Leaf) -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Локальная конфигурация неполна: installation.json отсутствует. Ничего не перезаписано.'
  }

  $initialFingerprint = $null
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    # Perform hardware discovery before creating directories so a failed preflight
    # does not leave an empty data folder that looks like an interrupted install.
    $initialFingerprint = Get-PilotMachineFingerprint
  }

  foreach ($directory in @('data\postgres', 'data\redis', 'data\server-storage', 'data\license-state', 'config', 'license', 'backups', 'logs', '.private')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
  }

  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    $installation = [ordered]@{
      schema_version = 1
      installation_id = [Guid]::NewGuid().ToString().ToLowerInvariant()
      machine_fingerprint = $initialFingerprint
      created_at = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($configPath, ($installation | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
  }

  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    $installation = Get-PilotInstallation
    $projectName = 'mahabbat-' + ([string]$installation.installation_id).Substring(0, 8)
    foreach ($port in @($CrmPort, $PosPort, $LicenseStatusPort, $PrintGatewayPort)) {
      if (-not (Test-PilotPortAvailable -Port $port)) { throw "Порт $port уже занят. Закройте приложение, использующее порт, или запустите install.ps1 с другими портами." }
    }
    $environment = @"
COMPOSE_PROJECT_NAME=$projectName
PG_DATABASE_NAME=mahabbat
PG_DATABASE_USER=mahabbat
PG_DATABASE_PASSWORD=$(New-PilotRandomHex 32)
ENCRYPTION_KEY=$(New-PilotRandomHex 32)
FALLBACK_ENCRYPTION_KEY=$(New-PilotRandomHex 32)
APP_SECRET=$(New-PilotRandomHex 32)
MAHABBAT_INTERNAL_ROUTE_SECRET=$(New-PilotRandomHex 32)
TWENTY_API_KEY=
MAHABBAT_API_KEY=
TWENTY_APP_ACCESS_TOKEN=
SERVER_URL=http://localhost:$CrmPort
CRM_PORT=$CrmPort
POS_PORT=$PosPort
LICENSE_STATUS_PORT=$LicenseStatusPort
PRINT_GATEWAY_PORT=$PrintGatewayPort
PRINT_GATEWAY_URL=http://host.docker.internal:$PrintGatewayPort
POS_CORS_ORIGIN=http://localhost:$PosPort,http://127.0.0.1:$PosPort
"@
    Set-PilotPrivateFile -Path $envPath -Content $environment
  }

  $installation = Assert-PilotMachineBinding
  $requestPath = Join-Path $root 'license\activation-request.json'
  if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    $request = [ordered]@{
      product = 'Mahabbat'
      schema_version = 1
      installation_id = [string]$installation.installation_id
      machine_fingerprint = [string]$installation.machine_fingerprint
      requested_at = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
  }

  Start-PilotDockerDesktop
  $manifest = Get-Content -LiteralPath (Join-Path $root 'image-manifest.json') -Raw | ConvertFrom-Json
  if ([int]$manifest.schema_version -ne 1 -or @($manifest.images).Count -lt 5 -or
      @($manifest.images | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.reference) -or [string]::IsNullOrWhiteSpace([string]$_.imageId) }).Count -gt 0) {
    throw 'Manifest образов повреждён или неполон. Runtime не запускался.'
  }
  $imageMissing = @($manifest.images | Where-Object {
      $null -eq (& docker.exe image inspect ([string]$_.reference) --format '{{.Id}}' 2>$null)
    }).Count -gt 0
  if ($imageMissing) {
    & docker.exe load --input (Join-Path $root 'runtime-images.tar')
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось загрузить локальные образы Mahabbat.' }
  }
  $missingAfterLoad = @($manifest.images | Where-Object {
      $null -eq (& docker.exe image inspect ([string]$_.reference) --format '{{.Id}}' 2>$null)
    })
  if ($missingAfterLoad.Count -gt 0) { throw 'В образном архиве не хватает обязательных компонентов Mahabbat.' }

  Invoke-PilotCompose @('config', '--quiet')
  Invoke-PilotCompose @('up', '-d')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw 'Сервисы запускаются дольше обычного. Проверьте status.ps1; данные сохранены.' }
  Start-PilotPrintGateway

  $desktop = [Environment]::GetFolderPath('Desktop')
  if ($desktop) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $desktop 'Mahabbat.lnk'))
    $shortcut.TargetPath = (Join-Path $PSHOME 'powershell.exe')
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'start.ps1')
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = 'Запустить Mahabbat'
    $shortcut.Save()
  }

  $urls = Get-PilotUrlMap
  $license = Get-PilotLicenseStatus
  Write-Host 'Установка Mahabbat завершена.'
  Write-Host "CRM: $($urls.Crm)"
  Write-Host "POS: $($urls.Pos)"
  Write-Host "Запрос активации: $requestPath"
  if ($license.active) { Write-Host "Лицензия активна до $($license.expiresAt)." }
  else { Write-Host 'Лицензия ещё не активирована. Передайте activation-request.json сопровождающему и затем запустите activate.ps1.' }
  Start-Process $urls.Crm
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
