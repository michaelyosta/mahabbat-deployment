[CmdletBinding()]
param([int]$TimeoutSeconds = 240)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  Assert-MahabbatDockerEngine
  $missing = @(Test-MahabbatEnvironment)
  if ($missing.Count -gt 0) { throw "Missing required .env values: $($missing -join ', ')" }
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path). Run mahabbat-bootstrap.ps1." }
  if (-not $inner.Match) { throw "Inner HEAD does not match mahabbat-inner.lock.json. Expected $($inner.Expected), actual $($inner.Actual)." }
  if ($inner.Dirty) { throw 'Inner repository has uncommitted changes. Resolve them before starting deployment.' }
  if (-not (Test-MahabbatComposeConfig)) { throw 'docker compose config validation failed.' }

  $requiredImages = @('mahabbat-twenty:v2.29.0-branding', 'mahabbat-pos-gateway:local')
  $missingImages = @($requiredImages | Where-Object {
      $null -eq (& docker image inspect $_ --format '{{.Id}}' 2>$null)
    })
  if ($missingImages.Count -gt 0) {
    Write-Host ('Building missing images: {0}' -f ($missingImages -join ', '))
    Invoke-MahabbatCompose @('build')
  }
  Invoke-MahabbatCompose @('up', '-d')
  if (-not (Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds)) { throw 'Runtime health checks did not converge in time.' }

  $crm = Test-MahabbatUrl 'http://localhost:3000/' @(200, 301, 302, 303, 307, 308)
  $crmHealth = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/' @(200, 301, 302, 303, 307, 308)
  $posHealth = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  if (-not $crm.Pass -or -not $crmHealth.Pass -or -not $pos.Pass -or -not $posHealth.Pass) {
    throw 'Local CRM/POS health verification failed.'
  }

  $cloud = Get-MahabbatCloudflaredState
  if ($cloud.ServicePresent -and $cloud.Status -ne 'Running') {
    try { Start-Service -Name $cloud.ServiceName -ErrorAction Stop; $cloud = Get-MahabbatCloudflaredState } catch { Write-Warning 'Cloudflared service is installed but could not be started.' }
  } elseif (-not $cloud.ServicePresent -and -not $cloud.ManagedProcessPresent -and (Test-Path -LiteralPath (Get-MahabbatCloudflaredTokenFile) -PathType Leaf)) {
    try { Start-MahabbatCloudflaredManagedProcess; $cloud = Get-MahabbatCloudflaredState } catch { Write-Warning $_.Exception.Message }
  }

  Write-Host ''
  Write-Host 'MAHABBAT'
  Write-MahabbatServiceTable @(Get-MahabbatRuntimeSnapshot)
  Write-Host ('Cloudflare      {0}' -f $cloud.Status.ToUpperInvariant())
  Write-Host ''
  Write-Host 'CRM local:'
  Write-Host 'http://localhost:3000'
  Write-Host 'POS local:'
  Write-Host 'http://localhost:3100'
  Write-Host 'CRM public:'
  Write-Host 'https://crm-pilot.showalove.ru'
  Write-Host 'POS public:'
  Write-Host 'https://pos-pilot.showalove.ru'
  if ($cloud.Status -eq 'Running') { Write-Host 'READY' } else { Write-Host 'LOCAL READY; CLOUDFLARE PENDING' }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
