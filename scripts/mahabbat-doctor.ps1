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

$cloud = Get-MahabbatCloudflaredState
if (-not $cloud.Installed) { $issues += 'cloudflared is not installed.' }
elseif (-not $cloud.ServicePresent) { $issues += 'cloudflared is installed but no Windows service is present.' }
elseif ($cloud.Status -ne 'Running') { $issues += "cloudflared service is $($cloud.Status)." }
else { Write-Host 'CLOUDFLARED     PASS' }

$crmPublic = Test-MahabbatUrl 'https://crm-pilot.showalove.ru/' @(200, 301, 302, 303, 307, 308, 401, 403)
$posPublic = Test-MahabbatUrl 'https://pos-pilot.showalove.ru/' @(200, 301, 302, 303, 307, 308, 401, 403)
if ($crmPublic.Pass -and $posPublic.Pass) { Write-Host 'PUBLIC          ACCESS/REACHABLE' }
else { $issues += "Public endpoints are not reachable (CRM $($crmPublic.Code), POS $($posPublic.Code))." }

if ($issues.Count -eq 0) {
  Write-Host 'DOCTOR PASS'
  exit 0
}

Write-Host ''
Write-Host 'BLOCKED:'
foreach ($issue in $issues) { Write-Host "- $issue" }
exit 1
