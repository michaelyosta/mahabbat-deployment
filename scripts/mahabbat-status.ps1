[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

Write-Host 'MAHABBAT STATUS'
$dockerOk = Test-MahabbatDockerEngine
Write-Host ('DOCKER ENGINE   {0}' -f ($(if ($dockerOk) { 'PASS' } else { 'UNAVAILABLE' })))

try {
  $inner = Get-MahabbatInnerState
  Write-Host "INNER           $($inner.Actual)"
  Write-Host "LOCK            $($inner.Expected)"
  Write-Host ('LOCK MATCH      {0}' -f ($(if ($inner.Match) { 'MATCH' } else { 'MISMATCH' })))
  Write-Host ('INNER DIRTY     {0}' -f ($(if ($inner.Dirty) { 'DIRTY' } else { 'CLEAN' })))
} catch { Write-Host ('INNER/LOCK      ERROR: {0}' -f $_.Exception.Message) }

$envPath = Join-Path (Get-MahabbatRoot) '.env'
Write-Host ('ENV             {0}' -f ($(if (Test-Path -LiteralPath $envPath -PathType Leaf) { 'PRESENT' } else { 'MISSING' })))

if ($dockerOk) {
  $snapshot = @(Get-MahabbatRuntimeSnapshot)
  Write-MahabbatServiceTable $snapshot
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  Write-Host ('CRM :3000       {0} ({1})' -f ($(if ($crm.Pass) { 'HEALTHY' } else { 'DOWN' }), $crm.Code))
  Write-Host ('POS :3100        {0} ({1})' -f ($(if ($pos.Pass) { 'HEALTHY' } else { 'DOWN' }), $pos.Code))
} else {
  Write-Host 'RUNTIME         unavailable because Docker Engine is not reachable.'
}

$printGateway = Get-MahabbatPrintGatewayState
Write-Host ('PRINT GATEWAY    {0}' -f $printGateway.Health)
Write-Host ('WINDOWS PRINTERS {0} DISCOVERED' -f (Get-MahabbatWindowsPrinterCount))

$cloud = Get-MahabbatCloudflaredState
$cloudLabel = if ($cloud.ServicePresent) { 'TUNNEL SERVICE' } elseif ($cloud.ManagedProcessPresent) { 'TUNNEL PROCESS' } else { 'TUNNEL CONNECTOR' }
Write-Host ('{0,-15} {1}' -f $cloudLabel, $cloud.Status.ToUpperInvariant())
$crmPublic = Test-MahabbatUrl 'https://crm-pilot.showalove.ru/' @(200, 301, 302, 303, 307, 308, 401, 403)
$posPublic = Test-MahabbatUrl 'https://pos-pilot.showalove.ru/' @(200, 301, 302, 303, 307, 308, 401, 403)
Write-Host ('CRM public      {0} ({1})' -f ($(if ($crmPublic.Pass) { 'REACHABLE/ACCESS' } else { 'DOWN' }), $crmPublic.Code))
Write-Host ('POS public      {0} ({1})' -f ($(if ($posPublic.Pass) { 'REACHABLE/ACCESS' } else { 'DOWN' }), $posPublic.Code))
Write-Host 'DATA            Persistent named volumes are defined; legacy data status is UNAVAILABLE.'
