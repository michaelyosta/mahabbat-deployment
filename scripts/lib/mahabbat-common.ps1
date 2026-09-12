Set-StrictMode -Version Latest

$script:MahabbatRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
$script:MahabbatComposeFile = Join-Path $script:MahabbatRoot 'docker-compose.yml'
$script:MahabbatServices = @('db', 'redis', 'server', 'worker', 'pos-gateway')
$script:MahabbatHealthServices = @('db', 'redis', 'server', 'pos-gateway')

function Get-MahabbatRoot {
  return $script:MahabbatRoot
}

function Get-MahabbatComposeArguments {
  $envPath = Join-Path $script:MahabbatRoot '.env'
  return @('--env-file', $envPath, '-f', $script:MahabbatComposeFile)
}

function Assert-MahabbatCommand {
  param([Parameter(Mandatory = $true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command is not available: $Name"
  }
}

function Test-MahabbatDockerEngine {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
  $null = & docker version --format '{{.Server.Version}}' 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Assert-MahabbatDockerEngine {
  Assert-MahabbatCommand 'docker'
  if (-not (Test-MahabbatDockerEngine)) {
    throw 'Docker Engine is unavailable. Start Docker Desktop and retry.'
  }
}

function Get-MahabbatEnvMap {
  $result = [ordered]@{}
  $envPath = Join-Path $script:MahabbatRoot '.env'
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $result }

  foreach ($line in Get-Content -LiteralPath $envPath -ErrorAction Stop) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      $result[$matches[1]] = $value
    }
  }
  return $result
}

function Get-MahabbatEnvValue {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Default = ''
  )
  if ($Map.Contains($Name)) { return [string]$Map[$Name] }
  return $Default
}

function Get-MahabbatLock {
  $lockPath = Join-Path $script:MahabbatRoot 'mahabbat-inner.lock.json'
  if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw 'mahabbat-inner.lock.json is missing.'
  }
  try {
    return (Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json)
  } catch {
    throw 'mahabbat-inner.lock.json is invalid JSON.'
  }
}

function Get-MahabbatInnerState {
  $lock = Get-MahabbatLock
  $relativePath = [string]$lock.expectedLocalPath
  $innerPath = [IO.Path]::GetFullPath((Join-Path $script:MahabbatRoot $relativePath))
  $expected = [string]$lock.commit
  $actual = ''
  $present = Test-Path -LiteralPath (Join-Path $innerPath '.git')
  if ($present) {
    $actual = ((& git -C $innerPath rev-parse HEAD 2>$null) -join '').Trim()
  }
  return [pscustomobject]@{
    Repository = [string]$lock.repository
    ExpectedPath = $relativePath
    Path = $innerPath
    Expected = $expected
    Actual = $actual
    Present = $present
    Match = ($present -and $actual -eq $expected)
    Dirty = if ($present) { [bool]((& git -C $innerPath status --porcelain 2>$null) -join '') } else { $false }
  }
}

function Test-MahabbatEnvironment {
  $required = @('PG_DATABASE_PASSWORD', 'ENCRYPTION_KEY', 'MAHABBAT_INTERNAL_ROUTE_SECRET')
  $envMap = Get-MahabbatEnvMap
  $missing = @()
  $envPath = Join-Path $script:MahabbatRoot '.env'
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    return @('.env')
  }
  foreach ($name in $required) {
    if (-not $envMap.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$envMap[$name]) -or ([string]$envMap[$name]).StartsWith('<')) {
      $missing += $name
    }
  }
  return $missing
}

function Invoke-MahabbatCompose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  Assert-MahabbatDockerEngine
  $composeArgs = @(Get-MahabbatComposeArguments) + @($Arguments)
  Push-Location $script:MahabbatRoot
  try {
    & docker compose @composeArgs
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($exitCode -ne 0) { throw 'docker compose command failed.' }
}

function Test-MahabbatComposeConfig {
  if (-not (Test-Path -LiteralPath $script:MahabbatComposeFile -PathType Leaf)) { return $false }
  if (-not (Test-Path -LiteralPath (Join-Path $script:MahabbatRoot '.env') -PathType Leaf)) { return $false }
  if (-not (Test-MahabbatDockerEngine)) { return $false }
  $composeArgs = @(Get-MahabbatComposeArguments) + @('config', '--quiet')
  Push-Location $script:MahabbatRoot
  try {
    & docker compose @composeArgs *> $null
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  return ($exitCode -eq 0)
}

function Get-MahabbatServiceContainerId {
  param([Parameter(Mandatory = $true)][string]$Service)
  if (-not (Test-MahabbatDockerEngine)) { return '' }
  $composeArgs = @(Get-MahabbatComposeArguments) + @('ps', '-q', $Service)
  Push-Location $script:MahabbatRoot
  try {
    $id = ((& docker compose @composeArgs 2>$null) -join '').Trim()
  } finally {
    Pop-Location
  }
  return $id
}

function Get-MahabbatContainerState {
  param([Parameter(Mandatory = $true)][string]$ContainerId)
  $raw = ((& docker inspect $ContainerId --format '{{json .State}}' 2>$null) -join '').Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{ State = 'missing'; Health = 'missing'; Id = $ContainerId }
  }
  $state = $raw | ConvertFrom-Json
  $health = 'none'
  if ($state.PSObject.Properties.Name -contains 'Health' -and $null -ne $state.Health) {
    $health = [string]$state.Health.Status
  }
  return [pscustomobject]@{
    State = [string]$state.Status
    Health = $health
    Id = $ContainerId
  }
}

function Get-MahabbatRuntimeSnapshot {
  $rows = @()
  foreach ($service in $script:MahabbatServices) {
    $id = Get-MahabbatServiceContainerId $service
    if ([string]::IsNullOrWhiteSpace($id)) {
      $rows += [pscustomobject]@{ Service = $service; State = 'missing'; Health = 'missing'; Id = '' }
    } else {
      $state = Get-MahabbatContainerState $id
      $rows += [pscustomobject]@{ Service = $service; State = $state.State; Health = $state.Health; Id = $state.Id }
    }
  }
  return $rows
}

function Test-MahabbatServiceReady {
  param([Parameter(Mandatory = $true)][psobject]$Row)
  if ($Row.State -ne 'running') { return $false }
  if ($script:MahabbatHealthServices -contains $Row.Service) {
    return ($Row.Health -eq 'healthy')
  }
  return $true
}

function Wait-MahabbatRuntime {
  param([int]$TimeoutSeconds = 240)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host 'Waiting for Mahabbat health checks...'
  do {
    $snapshot = @(Get-MahabbatRuntimeSnapshot)
    $ready = $true
    foreach ($service in $script:MahabbatServices) {
      $row = $snapshot | Where-Object Service -eq $service | Select-Object -First 1
      if ($null -eq $row -or -not (Test-MahabbatServiceReady $row)) { $ready = $false; break }
    }
    if ($ready) { return $true }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Test-MahabbatUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int[]]$AcceptedStatusCodes = @(200)
  )
  if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ Pass = $false; Code = 'curl-missing'; Url = $Url }
  }
  $code = ((& curl.exe --silent --show-error --output NUL --write-out '%{http_code}' --connect-timeout 4 --max-time 12 $Url 2>$null) -join '').Trim()
  $pass = ($LASTEXITCODE -eq 0 -and $AcceptedStatusCodes -contains ([int]($code -as [int])))
  return [pscustomobject]@{ Pass = $pass; Code = if ($code) { $code } else { 'unreachable' }; Url = $Url }
}

function Get-MahabbatCloudflaredService {
  $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '(?i)cloudflared' -or $_.DisplayName -match '(?i)cloudflare'
    })
  return ($services | Select-Object -First 1)
}

function Get-MahabbatCloudflaredExecutable {
  $command = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($null -ne $command) { return [string]$command.Source }
  foreach ($candidate in @(
      (Join-Path $script:MahabbatRoot '.cloudflared/cloudflared-windows-amd64.exe'),
      (Join-Path $script:MahabbatRoot '.cloudflared/cloudflared.exe')
    )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return ''
}

function Get-MahabbatCloudflaredTokenFile {
  return (Join-Path $script:MahabbatRoot '.cloudflared/mahabbat-pilot-review.token')
}

function Get-MahabbatCloudflaredPidFile {
  return (Join-Path $script:MahabbatRoot '.cloudflared/cloudflared.pid')
}

function Get-MahabbatCloudflaredManagedProcess {
  $pidPath = Get-MahabbatCloudflaredPidFile
  if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $null }
  try { $processId = [int](Get-Content -Raw -LiteralPath $pidPath).Trim() } catch { return $null }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $process) { return $null }
  if ($process.ProcessName -notmatch '(?i)cloudflared') { return $null }
  return $process
}

function Get-MahabbatCloudflaredState {
  $executable = Get-MahabbatCloudflaredExecutable
  $service = Get-MahabbatCloudflaredService
  $managedProcess = Get-MahabbatCloudflaredManagedProcess
  return [pscustomobject]@{
    Installed = (-not [string]::IsNullOrWhiteSpace($executable))
    Executable = $executable
    ServicePresent = ($null -ne $service)
    ServiceName = if ($null -ne $service) { [string]$service.Name } else { '' }
    ManagedProcessPresent = ($null -ne $managedProcess)
    ManagedProcessId = if ($null -ne $managedProcess) { [int]$managedProcess.Id } else { 0 }
    Status = if ($null -ne $service) { [string]$service.Status } elseif ($null -ne $managedProcess) { 'Running' } elseif (-not [string]::IsNullOrWhiteSpace($executable)) { 'no-service' } else { 'not-installed' }
  }
}

function Start-MahabbatCloudflaredManagedProcess {
  $state = Get-MahabbatCloudflaredState
  if ($state.ServicePresent) {
    if ($state.Status -ne 'Running') { Start-Service -Name $state.ServiceName }
    return
  }
  if ($state.ManagedProcessPresent) { return }
  if (-not $state.Installed) { throw 'cloudflared is not installed.' }
  $tokenPath = Get-MahabbatCloudflaredTokenFile
  if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
    throw "Existing tunnel token file is missing at $tokenPath. Store it locally and never commit it."
  }
  $token = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
  if ([string]::IsNullOrWhiteSpace($token)) { throw 'Existing tunnel token file is empty.' }
  $logDir = Join-Path $script:MahabbatRoot '.cloudflared'
  [IO.Directory]::CreateDirectory($logDir) | Out-Null
  $stdoutPath = Join-Path $logDir 'cloudflared.out.log'
  $stderrPath = Join-Path $logDir 'cloudflared.err.log'
  $arguments = @('tunnel', '--no-autoupdate', 'run', '--token', $token)
  $process = Start-Process -FilePath $state.Executable -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
  [IO.File]::WriteAllText((Get-MahabbatCloudflaredPidFile), [string]$process.Id, [Text.UTF8Encoding]::new($false))
  Remove-Variable token,arguments -ErrorAction SilentlyContinue
}

function Test-MahabbatPortListening {
  param([Parameter(Mandatory = $true)][int]$Port)
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    return ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1))
  }
  $text = (& netstat.exe -ano -p tcp 2>$null) -join "`n"
  return ($text -match (':{0}\s+.*LISTENING' -f $Port))
}

function Get-MahabbatPrintGatewayPidFile {
  return (Join-Path (Join-Path (Get-MahabbatRoot) '.private') 'print-gateway.pid')
}

function Get-MahabbatPrintGatewayProcess {
  $pidPath = Get-MahabbatPrintGatewayPidFile
  if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $null }
  try { $processId = [int](Get-Content -Raw -LiteralPath $pidPath).Trim() } catch { return $null }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $process -or $process.ProcessName -notmatch '(?i)node') { return $null }
  return $process
}

function Get-MahabbatPrintGatewayState {
  $process = Get-MahabbatPrintGatewayProcess
  $health = Test-MahabbatUrl 'http://127.0.0.1:3110/health' @(200)
  return [pscustomobject]@{
    ProcessPresent = ($null -ne $process)
    ProcessId = if ($null -ne $process) { [int]$process.Id } else { 0 }
    Health = if ($health.Pass) { 'HEALTHY' } elseif ($null -ne $process) { 'UNHEALTHY' } else { 'STOPPED' }
    Code = $health.Code
  }
}

function Start-MahabbatPrintGateway {
  $existing = Get-MahabbatPrintGatewayProcess
  if ($null -ne $existing) { return $existing }
  Assert-MahabbatCommand 'node'
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path)." }
  $envMap = Get-MahabbatEnvMap
  $privateDir = Join-Path (Get-MahabbatRoot) '.private'
  New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
  $stdoutPath = Join-Path $privateDir 'print-gateway.out.log'
  $stderrPath = Join-Path $privateDir 'print-gateway.err.log'
  $names = @('TWENTY_API_URL', 'MAHABBAT_INTERNAL_ROUTE_SECRET', 'PRINT_GATEWAY_HOST', 'PRINT_GATEWAY_PORT')
  $previous = @{}
  foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  try {
    $env:TWENTY_API_URL = Get-MahabbatEnvValue $envMap 'TWENTY_API_URL' 'http://127.0.0.1:3000'
    $env:MAHABBAT_INTERNAL_ROUTE_SECRET = Get-MahabbatEnvValue $envMap 'MAHABBAT_INTERNAL_ROUTE_SECRET'
    $env:PRINT_GATEWAY_HOST = Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_HOST' '0.0.0.0'
    $env:PRINT_GATEWAY_PORT = Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_PORT' '3110'
    $process = Start-Process -FilePath ((Get-Command node).Source) -ArgumentList @('pos-standalone/server/print-gateway.mjs') -WorkingDirectory $inner.Path -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    [IO.File]::WriteAllText((Get-MahabbatPrintGatewayPidFile), [string]$process.Id, [Text.UTF8Encoding]::new($false))
    return $process
  } finally {
    foreach ($name in $names) {
      if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
      else { Set-Item -LiteralPath "Env:$name" -Value $previous[$name] }
    }
  }
}

function Wait-MahabbatPrintGateway {
  param([int]$TimeoutSeconds = 30)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $state = Get-MahabbatPrintGatewayState
    if ($state.Health -eq 'HEALTHY') { return $true }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-MahabbatPrintGateway {
  $process = Get-MahabbatPrintGatewayProcess
  if ($null -ne $process) {
    try { Stop-Process -Id $process.Id -ErrorAction Stop } catch { return $false }
  }
  $pidPath = Get-MahabbatPrintGatewayPidFile
  if (Test-Path -LiteralPath $pidPath -PathType Leaf) { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue }
  return $true
}

function Get-MahabbatWindowsPrinterCount {
  if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) { return 0 }
  return @((Get-Printer -ErrorAction SilentlyContinue)).Count
}

function Get-MahabbatPrinterBindingState {
  $unknown = [pscustomobject]@{
    Available = $false
    ConfiguredCount = 0
    BrokenCount = 0
    Error = 'PrinterDevice state is unavailable.'
  }
  try {
    $envMap = Get-MahabbatEnvMap
    $apiUrl = Get-MahabbatEnvValue $envMap 'SERVER_URL' 'http://127.0.0.1:3000'
    $apiKey = Get-MahabbatEnvValue $envMap 'TWENTY_API_KEY'
    if ([string]::IsNullOrWhiteSpace($apiKey) -or $apiKey.StartsWith('<')) {
      $unknown.Error = 'TWENTY_API_KEY is missing.'
      return $unknown
    }
    $headers = @{ Authorization = "Bearer $apiKey" }
    $response = Invoke-RestMethod -UseBasicParsing -Uri "$($apiUrl.TrimEnd('/'))/rest/posPrinterDevices?limit=200" -Headers $headers -ErrorAction Stop
    $devices = @($response.data.posPrinterDevices)
    $queues = @()
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
      $queues = @((Get-Printer -ErrorAction SilentlyContinue) | ForEach-Object { [string]$_.Name })
    }
    $broken = @($devices | Where-Object {
      $queue = [string]$_.systemQueueName
      $queue -and (($queues -notcontains $queue) -or ([string]$_.connectionType -eq 'WINDOWS_SPOOLER' -and $queues -notcontains $queue))
    })
    return [pscustomobject]@{
      Available = $true
      ConfiguredCount = $devices.Count
      BrokenCount = $broken.Count
      Error = ''
    }
  } catch {
    $unknown.Error = 'Could not read PrinterDevice state from the local API.'
    return $unknown
  }
}

function Write-MahabbatServiceTable {
  param([Parameter(Mandatory = $true)][array]$Snapshot)
  foreach ($row in $Snapshot) {
    $label = switch ($row.Service) {
      'pos-gateway' { 'POS' }
      'server' { 'Twenty' }
      default { $row.Service }
    }
    $health = if ($row.Health -eq 'none') { $row.State } else { $row.Health }
    Write-Host ('{0,-15} {1}' -f $label, $health.ToUpperInvariant())
  }
}

function Stop-MahabbatCloudflaredService {
  $service = Get-MahabbatCloudflaredService
  $ok = $true
  if ($null -ne $service -and $service.Status -eq 'Running') {
    try {
      Stop-Service -Name $service.Name -ErrorAction Stop
    } catch {
      Write-Warning 'Could not stop cloudflared service. Run PowerShell as Administrator if needed.'
      $ok = $false
    }
  }
  $managedProcess = Get-MahabbatCloudflaredManagedProcess
  if ($null -ne $managedProcess) {
    try { Stop-Process -Id $managedProcess.Id -Force -ErrorAction Stop } catch { $ok = $false }
  }
  $pidPath = Get-MahabbatCloudflaredPidFile
  if (Test-Path -LiteralPath $pidPath -PathType Leaf) { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue }
  return $ok
}
