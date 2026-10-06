Set-StrictMode -Version Latest

$script:MahabbatRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') '..'))
$script:MahabbatComposeFile = Join-Path $script:MahabbatRoot 'docker-compose.yml'
$script:MahabbatServices = @('db', 'redis', 'server', 'worker', 'pos-gateway')
$script:MahabbatHealthServices = @('db', 'redis', 'server', 'worker', 'pos-gateway')

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

function Set-MahabbatPrivateFileAcl {
  # User-only ACL for secret files (.env, setup-token, DPAPI key, scoped env).
  # Best-effort: warns when icacls is unavailable instead of failing the caller.
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${user}:F" 'SYSTEM:F' 'Administrators:F' *> $null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restrict ACL on $Path; check sharing on this PC." }
  } catch {
    Write-Warning "Could not restrict ACL on ${Path}: $($_.Exception.Message)"
  }
}

function Set-MahabbatEnvAcl {
  # Restricts the deployment .env to the current user (+SYSTEM/Administrators).
  $envPath = Join-Path $script:MahabbatRoot '.env'
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return }
  Set-MahabbatPrivateFileAcl -Path $envPath
}

function Test-MahabbatEnvAcl {
  # $true when .env grants nothing to broad identities (Everyone/Users).
  # Missing .env returns $true: the missing-file case is reported separately.
  $envPath = Join-Path $script:MahabbatRoot '.env'
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $true }
  try {
    $acl = Get-Acl -LiteralPath $envPath
  } catch { return $false }
  $broad = @('Everyone', 'BUILTIN\Users', 'NT AUTHORITY\Authenticated Users', 'Users', 'Authenticated Users')
  foreach ($rule in $acl.Access) {
    if ($rule.AccessControlType -ne 'Allow') { continue }
    $id = [string]$rule.IdentityReference
    foreach ($b in $broad) {
      if (($id -eq $b) -or $id.EndsWith("\$b")) { return $false }
    }
  }
  return $true
}

function Invoke-MahabbatCompose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  Assert-MahabbatDockerEngine
  Assert-MahabbatNoDestructiveVolumeFlag -Arguments $Arguments
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

function Get-MahabbatComposeServiceImages {
  # Resolved images for the named stack services, honoring
  # MAHABBAT_TWENTY_IMAGE / MAHABBAT_POS_IMAGE / MAHABBAT_IMAGE_OWNER.
  # NetSetupCI contract: mahabbat-update.ps1 consumes this first and falls
  # back to `docker compose config --images`, then GHCR defaults.
  # NOTE: `docker compose config --images` ignores service-name filters in
  # Compose v5 (it lists every service image), so $Services is accepted for
  # a stable signature but filtering happens at the caller.
  param([string[]]$Services = @())
  Assert-MahabbatDockerEngine
  $composeArgs = @(Get-MahabbatComposeArguments) + @('config', '--images')
  Push-Location $script:MahabbatRoot
  try {
    $listed = @((& docker compose @composeArgs 2>$null))
  } finally {
    Pop-Location
  }
  if ($LASTEXITCODE -ne 0 -or $listed.Count -eq 0) { throw 'docker compose config --images returned no images.' }
  $rows = @()
  foreach ($line in $listed) {
    $text = ([string]$line).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $rows += [pscustomobject]@{ Image = $text }
  }
  return $rows
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
function Get-MahabbatImageDigestsLock {
  $lockPath = Join-Path $script:MahabbatRoot 'image-digests.lock.json'
  if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    throw 'image-digests.lock.json is missing.'
  }
  try {
    return (Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json)
  } catch {
    throw 'image-digests.lock.json is invalid JSON.'
  }
}

function Get-MahabbatRunningImageDigest {
  param([Parameter(Mandatory = $true)][string]$ContainerId)
  $raw = ((& docker inspect $ContainerId --format '{{.Image}}' 2>$null) -join '').Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
  return $raw.ToLowerInvariant()
}

function Test-MahabbatImageDigests {
  # Fail-closed: running images must resolve to the locked digests/names.
  # db/redis: exact pinned digest match. server/worker/pos-gateway: the
  # configured GHCR name must match image-digests.lock.json venue/posGateway
  # refs (owner-agnostic: any registry owner accepted, tag pattern enforced).
  # Returns an array of human-readable mismatches (empty = all pinned).
  $problems = @()
  try { $lock = Get-MahabbatImageDigestsLock } catch { return @($_.Exception.Message) }
  $pinned = @{
    db = ([string]$lock.images.postgres.pinned).ToLowerInvariant()
    redis = ([string]$lock.images.redis.pinned).ToLowerInvariant()
  }
  foreach ($service in @('db', 'redis')) {
    $id = Get-MahabbatServiceContainerId $service
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $digest = Get-MahabbatRunningImageDigest $id
    # docker inspect returns the content digest (sha256:...); accept it when
    # the locked pinned ref carries the same digest suffix.
    $expected = $pinned[$service]
    $expectedDigest = ''
    if ($expected -match '@(sha256:[0-9a-f]{64})$') { $expectedDigest = $Matches[1] }
    $localRef = ((& docker inspect $id --format '{{.Config.Image}}' 2>$null) -join '').Trim().ToLowerInvariant()
    $digestOk = ((-not [string]::IsNullOrWhiteSpace($expectedDigest)) -and ($digest -eq $expectedDigest -or $digest.EndsWith($expectedDigest) -or $localRef -eq $expected))
    if (-not $digestOk) {
      $problems += "Service $service image digest mismatch: running '$localRef' ($digest), locked '$expected'."
    }
  }
  $nameExpect = @{
    server = [string]$lock.images.venue.ref
    worker = [string]$lock.images.venue.ref
    'pos-gateway' = [string]$lock.images.posGateway.ref
  }
  foreach ($service in @('server', 'worker', 'pos-gateway')) {
    $id = Get-MahabbatServiceContainerId $service
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $running = ((& docker inspect $id --format '{{.Config.Image}}' 2>$null) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($running)) { $problems += "Service $service image is unreadable."; continue }
    # Owner-agnostic: compare repo path + tag only (ghcr.io/<owner>/<repo>:<tag>).
    $norm = { param([string]$s) return ([string]$s).Trim().ToLowerInvariant() -replace '^[^/]+/[^/]+/', '' }
    if ((&$norm $running) -ne (&$norm $nameExpect[$service])) {
      $problems += "Service $service image name mismatch: running '$running', locked '$($nameExpect[$service])'."
    }
  }
  return $problems
}

function Assert-MahabbatImageDigests {
  $problems = @(Test-MahabbatImageDigests)
  if ($problems.Count -gt 0) { throw ($problems -join "`n") }
}

function Get-MahabbatBackupRoot {
  # Backups live outside the installed app tree so uninstall never wipes them:
  # MAHABBAT_BACKUP_ROOT override, else %ProgramData%\Mahabbat\backups.
  $override = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_ROOT', 'Process')
  if ([string]::IsNullOrWhiteSpace($override)) { $override = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_ROOT', 'Machine') }
  if ([string]::IsNullOrWhiteSpace($override)) { $override = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_ROOT', 'User') }
  if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
  $programData = [Environment]::GetEnvironmentVariable('ProgramData', 'Machine')
  if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
  return (Join-Path $programData 'Mahabbat\backups')
}

function Get-MahabbatBackupRetentionCount {
  $raw = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_RETAIN', 'Process')
  if ([string]::IsNullOrWhiteSpace($raw)) { $raw = [string](Get-MahabbatEnvMap)['MAHABBAT_BACKUP_RETAIN'] }
  $count = 0
  if (-not [string]::IsNullOrWhiteSpace($raw)) { [int]::TryParse($raw.Trim(), [ref]$count) | Out-Null }
  if ($count -le 0) { $count = 14 }
  if ($count -gt 90) { $count = 90 }
  return $count
}

function Invoke-MahabbatBackupRetention {
  param([Parameter(Mandatory = $true)][string]$BackupRoot)
  $retain = Get-MahabbatBackupRetentionCount
  $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-\d{6}$' } |
    Sort-Object Name -Descending)
  if ($dirs.Count -le $retain) { return 0 }
  $pruned = 0
  foreach ($stale in @($dirs | Select-Object -Skip $retain)) {
    try { Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop; $pruned += 1 } catch { Write-Warning "Could not prune old backup $($stale.Name): $($_.Exception.Message)" }
  }
  return $pruned
}

function Assert-MahabbatNoDestructiveVolumeFlag {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $joined = ' ' + ($Arguments -join ' ') + ' '
  if ($joined -match '(?i)\sdown\s' -and $joined -match '(?i)\s(-v|--volumes)\s?') {
    throw "Refusing 'docker compose down -v/--volumes' for this stack: named volumes hold the live database. Use mahabbat-stop.ps1 (stop, volumes preserved)."
  }
  if ($joined -match '(?i)\bvolume\s+(prune|rm)\b') {
    throw "Refusing 'docker volume prune/rm' for this stack without MAHABBAT_ALLOW_VOLUME_PRUNE=1."
  }
  $allowPrune = [Environment]::GetEnvironmentVariable('MAHABBAT_ALLOW_VOLUME_PRUNE', 'Process')
  if ($joined -match '(?i)\bvolume\b' -and -not [string]::IsNullOrWhiteSpace($allowPrune) -and $allowPrune.Trim() -ne '1') {
    throw 'Volume operations require MAHABBAT_ALLOW_VOLUME_PRUNE=1.'
  }
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

function Get-MahabbatVenueName {
  $envMap = Get-MahabbatEnvMap
  $name = (Get-MahabbatEnvValue $envMap 'MAHABBAT_VENUE_NAME' '').Trim()
  if ([string]::IsNullOrWhiteSpace($name)) { return 'Махаббат' }
  return $name
}

function Get-MahabbatTunnelName {
  $envMap = Get-MahabbatEnvMap
  $name = (Get-MahabbatEnvValue $envMap 'MAHABBAT_TUNNEL_NAME' '').Trim()
  if ([string]::IsNullOrWhiteSpace($name)) { return 'mahabbat-pilot-review' }
  return $name
}

function Get-MahabbatPublicCrmUrl {
  $envMap = Get-MahabbatEnvMap
  return (Get-MahabbatEnvValue $envMap 'MAHABBAT_PUBLIC_CRM_URL' '').Trim()
}

function Get-MahabbatPublicPosUrl {
  $envMap = Get-MahabbatEnvMap
  return (Get-MahabbatEnvValue $envMap 'MAHABBAT_PUBLIC_POS_URL' '').Trim()
}

function Get-MahabbatPrintGatewayId {
  $envMap = Get-MahabbatEnvMap
  return (Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_ID' '').Trim()
}

function Test-MahabbatPublicEndpointsConfigured {
  $crm = Get-MahabbatPublicCrmUrl
  $pos = Get-MahabbatPublicPosUrl
  return (-not [string]::IsNullOrWhiteSpace($crm) -or -not [string]::IsNullOrWhiteSpace($pos))
}

function Get-MahabbatCloudflaredTokenFile {
  return (Join-Path $script:MahabbatRoot ('.cloudflared/' + (Get-MahabbatTunnelName) + '.token'))
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
  # Токен — только через config-файл (user-only ACL), никогда в argv (видно в ps).
  $configPath = Join-Path $logDir 'managed-config.yml'
  $configText = "tunnelToken: $token`nno-autoupdate: true`n"
  $token = $null
  Remove-Variable token -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($configPath, $configText, [Text.UTF8Encoding]::new($false))
  Set-MahabbatPrivateFileAcl -Path $configPath
  $arguments = @('tunnel', '--config', $configPath, 'run')
  $process = Start-Process -FilePath $state.Executable -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
  [IO.File]::WriteAllText((Get-MahabbatCloudflaredPidFile), [string]$process.Id, [Text.UTF8Encoding]::new($false))
  Remove-Variable configText,arguments -ErrorAction SilentlyContinue
}

function Test-MahabbatPortListening {
  param([Parameter(Mandatory = $true)][int]$Port)
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    return ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1))
  }
  $text = (& netstat.exe -ano -p tcp 2>$null) -join "`n"
  return ($text -match (':{0}\s+.*LISTENING' -f $Port))
}

function Get-MahabbatPrintGatewayMode {
  $envMap = Get-MahabbatEnvMap
  $mode = (Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_MODE' 'LOCAL').Trim().ToUpperInvariant()
  if ($mode -notin @('LOCAL', 'REMOTE')) {
    throw 'PRINT_GATEWAY_MODE must be LOCAL or REMOTE.'
  }
  return $mode
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
  $mode = Get-MahabbatPrintGatewayMode
  if ($mode -eq 'REMOTE') {
    return [pscustomobject]@{
      ProcessPresent = $false
      ProcessId = 0
      Health = 'REMOTE'
      Code = 'REMOTE_CONFIGURED'
    }
  }
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
  if ((Get-MahabbatPrintGatewayMode) -eq 'REMOTE') { return $null }
  $existing = Get-MahabbatPrintGatewayProcess
  if ($null -ne $existing) { return $existing }
  $bundledNode = Join-Path (Get-MahabbatRoot) 'installer/app/runtime/node.exe'
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) { $nodeBin = $bundledNode }
  else { Assert-MahabbatCommand 'node'; $nodeBin = (Get-Command node).Source }
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path)." }
  $envMap = Get-MahabbatEnvMap
  $privateDir = Join-Path (Get-MahabbatRoot) '.private'
  New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
  $stdoutPath = Join-Path $privateDir 'print-gateway.out.log'
  $stderrPath = Join-Path $privateDir 'print-gateway.err.log'
  $names = @('TWENTY_API_URL', 'MAHABBAT_INTERNAL_ROUTE_SECRET', 'PRINT_GATEWAY_MODE', 'PRINT_GATEWAY_HOST', 'PRINT_GATEWAY_PORT')
  $previous = @{}
  foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  try {
    $env:TWENTY_API_URL = Get-MahabbatEnvValue $envMap 'TWENTY_API_URL' 'http://127.0.0.1:3000'
    $env:MAHABBAT_INTERNAL_ROUTE_SECRET = Get-MahabbatEnvValue $envMap 'MAHABBAT_INTERNAL_ROUTE_SECRET'
    $env:PRINT_GATEWAY_MODE = Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_MODE' 'LOCAL'
    $env:PRINT_GATEWAY_HOST = Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_HOST' '0.0.0.0'
    $env:PRINT_GATEWAY_PORT = Get-MahabbatEnvValue $envMap 'PRINT_GATEWAY_PORT' '3110'
    $process = Start-Process -FilePath $nodeBin -ArgumentList @('pos-standalone/server/print-gateway.mjs') -WorkingDirectory $inner.Path -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
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
  if ((Get-MahabbatPrintGatewayMode) -eq 'REMOTE') { return $true }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $state = Get-MahabbatPrintGatewayState
    if ($state.Health -eq 'HEALTHY') { return $true }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-MahabbatPrintGateway {
  if ((Get-MahabbatPrintGatewayMode) -eq 'REMOTE') { return $true }
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
