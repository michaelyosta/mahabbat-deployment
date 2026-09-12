Set-StrictMode -Version Latest

$script:MahabbatRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
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

function Get-MahabbatCloudflaredState {
  $executable = Get-MahabbatCloudflaredExecutable
  $service = Get-MahabbatCloudflaredService
  return [pscustomobject]@{
    Installed = (-not [string]::IsNullOrWhiteSpace($executable))
    Executable = $executable
    ServicePresent = ($null -ne $service)
    ServiceName = if ($null -ne $service) { [string]$service.Name } else { '' }
    Status = if ($null -ne $service) { [string]$service.Status } elseif (-not [string]::IsNullOrWhiteSpace($executable)) { 'no-service' } else { 'not-installed' }
  }
}

function Test-MahabbatPortListening {
  param([Parameter(Mandatory = $true)][int]$Port)
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    return ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1))
  }
  $text = (& netstat.exe -ano -p tcp 2>$null) -join "`n"
  return ($text -match (':{0}\s+.*LISTENING' -f $Port))
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
  if ($null -eq $service -or $service.Status -ne 'Running') { return $true }
  try {
    Stop-Service -Name $service.Name -ErrorAction Stop
    return $true
  } catch {
    Write-Warning 'Could not stop cloudflared service. Run PowerShell as Administrator if needed.'
    return $false
  }
}
