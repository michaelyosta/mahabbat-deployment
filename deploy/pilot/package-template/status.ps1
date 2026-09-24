[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

$root = Get-PilotRoot
$urls = $null
try { $urls = Get-PilotUrlMap } catch { }
Write-Host "Mahabbat version: $((Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim())"
$releaseManifestPath = Join-Path $root 'release-manifest.json'
if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
  try {
    $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
    if ($releaseManifest.build) { Write-Host "Build: $($releaseManifest.build)" }
  } catch { Write-Host 'Build: manifest unavailable' }
}
$installation = Get-PilotInstallation
if ($installation) {
  Write-Host "Installation: $($installation.installation_id)"
  try { Assert-PilotMachineBinding | Out-Null; Write-Host 'Computer binding: PASS' }
  catch { Write-Host "Computer binding: ERROR ($($_.Exception.Message))" }
} else { Write-Host 'Installation: NOT INITIALIZED' }

try {
  Assert-PilotDocker
  Write-Host 'Docker Engine: PASS'
  if (Test-Path -LiteralPath (Join-Path $root '.env')) {
    Invoke-PilotCompose @('ps')
  }
} catch { Write-Host "Docker Engine: UNAVAILABLE ($($_.Exception.Message))" }

if ($urls) {
  Write-Host ("CRM: {0} — {1}" -f $urls.Crm, $(if (Test-PilotUrl ($urls.Crm + '/healthz')) { 'READY' } else { 'DOWN' }))
  Write-Host ("POS: {0} — {1}" -f $urls.Pos, $(if (Test-PilotUrl ($urls.Pos + '/health')) { 'READY' } else { 'DOWN' }))
  $license = Get-PilotLicenseStatus
  Write-Host ("Лицензия: {0}{1}" -f $license.status, $(if ($license.expiresAt) { " · до $($license.expiresAt)" } else { '' }))
  Write-Host ("Служба печати: {0}" -f $(if (Test-PilotUrl $urls.PrintHealth) { 'READY' } else { 'OFFLINE' }))
}
Write-Host 'Секреты не выводятся.'
