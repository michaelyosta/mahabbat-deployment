[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

$issues = @()
Write-Host 'MAHABBAT DOCTOR'

if (-not (Test-MahabbatDockerEngine)) {
  $issues += 'Docker Engine is unavailable. Start Docker Desktop.'
} else {
  Write-Host 'DOCKER          PASS'
}

$missing = @(Test-MahabbatEnvironment)
if ($missing.Count -gt 0) {
  $issues += "Missing required .env values: $($missing -join ', ')"
} else {
  Write-Host 'ENV             PASS'
}
if (-not (Test-MahabbatEnvAcl)) {
  $issues += '.env ACL is too broad: restrict it to this user (icacls .env /inheritance:r /grant:r "%USERNAME%:F" SYSTEM:F Administrators:F).'
} else {
  Write-Host 'ENV ACL         PASS'
}

$bundledNode = Join-Path (Get-MahabbatRoot) 'installer/app/runtime/node.exe'
$nodeCmd = $null
if ((Test-Path -LiteralPath $bundledNode -PathType Leaf)) { $nodeCmd = $bundledNode }
elseif (Get-Command node -ErrorAction SilentlyContinue) { $nodeCmd = 'node' }
if ($null -eq $nodeCmd) {
  $issues += 'Node.js is not installed. Canonical toolchain is Node 24 (see mahabbat-app/.nvmrc).'
} else {
  $nodeVersion = (& $nodeCmd --version 2>$null) -join ''
  $nodeMajor = 0
  if ($nodeVersion -match '^v(\d+)\.') { $nodeMajor = [int]$Matches[1] }
  if ($nodeMajor -lt 24) {
    $issues += "Node $nodeVersion is unsupported; install Node 24 from mahabbat-app/.nvmrc before running tests/tooling."
  } else {
    Write-Host ('NODE            {0}' -f $nodeVersion)
  }
}

try {
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { $issues += "Inner repository is missing at $($inner.Path)." }
  elseif (-not $inner.Match) { $issues += "Inner HEAD mismatch. Expected $($inner.Expected), actual $($inner.Actual)." }
  elseif ($inner.Dirty) { $issues += 'Inner repository is dirty.' }
  else { Write-Host 'INNER/LOCK      PASS' }
} catch { $issues += $_.Exception.Message }

if (-not (Test-MahabbatComposeConfig)) { $issues += 'Compose configuration is invalid or cannot be checked.' } else { Write-Host 'COMPOSE         PASS' }

foreach ($port in @(3000, 3100)) {
  if (Test-MahabbatPortListening $port) { Write-Host "PORT $port        LISTENING" }
}

if (Test-MahabbatDockerEngine) {
  foreach ($row in @(Get-MahabbatRuntimeSnapshot)) {
    if (Test-MahabbatServiceReady $row) { Write-Host ('{0,-15} PASS' -f $row.Service) }
    else { $issues += "Service $($row.Service) is $($row.State)/$($row.Health)." }
  }
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  if ($crm.Pass) { Write-Host 'CRM LOCAL       PASS' } else { $issues += "CRM local health failed ($($crm.Code))." }
  if ($pos.Pass) { Write-Host 'POS LOCAL       PASS' } else { $issues += "POS local health failed ($($pos.Code))." }
}

$printGateway = Get-MahabbatPrintGatewayState
if ($printGateway.Health -eq 'REMOTE') {
  Write-Host 'PRINT GATEWAY   REMOTE CONFIGURED'
  Write-Host 'SPOOLER         REMOTE HOST (not checked here)'
  Write-Host 'WINDOWS PRINTERS REMOTE HOST (not enumerated here)'
} else {
  $spooler = Get-Service Spooler -ErrorAction SilentlyContinue
  if ($null -eq $spooler -or $spooler.Status -ne 'Running') { $issues += 'Windows Print Spooler is not running.' } else { Write-Host 'SPOOLER         PASS' }
  if ($printGateway.Health -eq 'HEALTHY') { Write-Host 'PRINT GATEWAY   PASS' } else { $issues += "Host print gateway is $($printGateway.Health). Run mahabbat-start.ps1." }
  $printerCount = Get-MahabbatWindowsPrinterCount
  if ($printerCount -gt 0) { Write-Host "WINDOWS PRINTERS $printerCount DISCOVERED" } else { $issues += 'No Windows printers were discovered.' }
  $bindings = Get-MahabbatPrinterBindingState
  if (-not $bindings.Available) { $issues += $bindings.Error }
  elseif ($bindings.BrokenCount -gt 0) { $issues += "$($bindings.BrokenCount) configured printer binding(s) are missing from Windows." }
  else {
    Write-Host "CONFIGURED DEVICES $($bindings.ConfiguredCount)"
    Write-Host 'BROKEN BINDINGS  0'
  }
}

$crmPublicUrl = Get-MahabbatPublicCrmUrl
$posPublicUrl = Get-MahabbatPublicPosUrl
if (Test-MahabbatPublicEndpointsConfigured) {
  $cloud = Get-MahabbatCloudflaredState
  if (-not $cloud.Installed) { $issues += 'cloudflared is not installed.' }
  elseif ($cloud.Status -ne 'Running') { $issues += "cloudflared is installed but not running ($($cloud.Status)); provide the tunnel token file via MAHABBAT_TUNNEL_NAME or start its service." }
  else { Write-Host 'CLOUDFLARED     PASS' }
  $crmPublic = $null; $posPublic = $null
  if (-not [string]::IsNullOrWhiteSpace($crmPublicUrl)) { $crmPublic = Test-MahabbatUrl $crmPublicUrl @(200, 301, 302, 303, 307, 308, 401, 403) }
  if (-not [string]::IsNullOrWhiteSpace($posPublicUrl)) { $posPublic = Test-MahabbatUrl $posPublicUrl @(200, 301, 302, 303, 307, 308, 401, 403) }
  $publicOk = $true
  if ($null -ne $crmPublic -and -not $crmPublic.Pass) { $publicOk = $false }
  if ($null -ne $posPublic -and -not $posPublic.Pass) { $publicOk = $false }
  if ($publicOk) { Write-Host 'PUBLIC          REACHABLE' }
  else {
    if ($null -ne $crmPublic) { $issues += "Public CRM endpoint is not reachable ($($crmPublic.Code))." }
    if ($null -ne $posPublic) { $issues += "Public POS endpoint is not reachable ($($posPublic.Code))." }
  }
} else {
  Write-Host 'PUBLIC          LOCAL ONLY (no public endpoints configured; skipping cloudflared checks)'
}

if ($issues.Count -eq 0) {
  Write-Host 'DOCTOR PASS'
  exit 0
}

Write-Host ''
Write-Host 'BLOCKED:'
foreach ($issue in $issues) { Write-Host "- $issue" }
exit 1
