[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  Assert-MahabbatDockerEngine
  $cloudStopped = Stop-MahabbatCloudflaredService
  if (-not (Test-Path -LiteralPath (Join-Path (Get-MahabbatRoot) '.env') -PathType Leaf)) {
    Write-Host 'Cloudflare stopped; .env is absent, so no Docker services were targeted.'
    exit 0
  }
  Invoke-MahabbatCompose @('stop')
  Write-Host 'Mahabbat runtime stopped safely. Persistent volumes were preserved.'
  if (-not $cloudStopped) { Write-Warning 'Cloudflared may still be running.' }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
