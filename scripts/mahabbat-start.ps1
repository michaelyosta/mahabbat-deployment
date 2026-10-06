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
  Assert-MahabbatImageDigests

  $requiredImages = @(@(Get-MahabbatComposeServiceImages -Services @('server', 'worker', 'pos-gateway')) | ForEach-Object { [string]$_.Image } | Sort-Object -Unique)
  $missingImages = @($requiredImages | Where-Object {
      $null -eq (& docker image inspect $_ --format '{{.Id}}' 2>$null)
    })
  if ($missingImages.Count -gt 0) {
    Write-Host 'Pulling prebuilt images first (registry may require `docker login ghcr.io`)...'
    try { Invoke-MahabbatCompose @('pull') } catch { Write-Warning 'Image pull failed; falling back to local build.' }
    $missingImages = @($requiredImages | Where-Object {
        $null -eq (& docker image inspect $_ --format '{{.Id}}' 2>$null)
      })
  }
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

  $printGatewayMode = Get-MahabbatPrintGatewayMode
  Start-MahabbatPrintGateway | Out-Null
  if (-not (Wait-MahabbatPrintGateway -TimeoutSeconds 30)) { throw 'Host print gateway did not become healthy.' }

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
  if ($printGatewayMode -eq 'REMOTE') {
    Write-Host 'Print Gateway   REMOTE (restaurant gateway polls outbound)'
  } else {
    Write-Host 'Print Gateway   HEALTHY'
  }
  Write-Host ''
  $venue = Get-MahabbatVenueName
  $crmPublicUrl = Get-MahabbatPublicCrmUrl
  $posPublicUrl = Get-MahabbatPublicPosUrl
  if (-not [string]::IsNullOrWhiteSpace($crmPublicUrl)) {
    Write-Host 'CRM public:'
    Write-Host $crmPublicUrl
  }
  if (-not [string]::IsNullOrWhiteSpace($posPublicUrl)) {
    Write-Host 'POS public:'
    Write-Host $posPublicUrl
  }
  if (-not (Test-MahabbatPublicEndpointsConfigured)) { Write-Host ('PUBLIC          LOCAL ONLY ({0})' -f $venue) }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
