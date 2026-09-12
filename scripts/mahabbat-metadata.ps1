[CmdletBinding()]
param(
  [ValidateSet('plan', 'apply')]
  [string]$Action = 'plan',
  [switch]$VerboseOutput
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  Assert-MahabbatDockerEngine
  $missing = @(Test-MahabbatEnvironment)
  if ($missing.Count -gt 0) { throw "Missing required .env values: $($missing -join ', ')" }
  $envMap = Get-MahabbatEnvMap
  $apiKey = Get-MahabbatEnvValue -Map $envMap -Name 'TWENTY_API_KEY'
  if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'TWENTY_API_KEY is missing. Create a local Twenty workspace API key and put it only in .env.' }
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path). Run mahabbat-bootstrap.ps1." }
  if (-not $inner.Match) { throw "Inner HEAD mismatch. Expected $($inner.Expected), actual $($inner.Actual)." }
  if ($inner.Dirty) { throw 'Inner repository has uncommitted changes.' }
  if (-not (Test-MahabbatComposeConfig)) { throw 'docker compose config validation failed.' }
  if (-not (Get-MahabbatServiceContainerId 'server')) { throw 'Twenty server container is not running. Run mahabbat-start.ps1 first.' }

  $root = Get-MahabbatRoot
  $innerPath = Join-Path $root 'mahabbat-app'
  $envPath = Join-Path $root '.env'
  $cliArgs = @(
    'run', '--rm', '--network', 'mahabbat_default',
    '--env-file', $envPath,
    '--env', 'TWENTY_API_URL=http://server:3000',
    '--env', 'MAHABBAT_API_URL=http://server:3000',
    '--mount', ('type=bind,source={0},target=/app' -f $innerPath),
    # Keep Linux CLI dependencies out of the Windows host node_modules tree.
    # In particular, sharp has platform-specific optional bindings.
    '--mount', 'type=volume,source=mahabbat_metadata_node_modules,target=/app/node_modules',
    '--workdir', '/app',
    'node:24-bookworm', 'bash', '-lc'
  )
  $verb = if ($VerboseOutput) { '-v' } else { '' }
  # The Twenty CLI keeps remote configuration separately from the runtime URL.
  # Re-register the disposable local remote in the ephemeral CLI container so
  # plan/apply is reproducible without persisting credentials in the repository.
  $command = if ($Action -eq 'plan') {
    'corepack enable && yarn install --immutable && yarn twenty remote:add --as selfhost-container --url http://server:3000 --api-key "$TWENTY_API_KEY" && yarn twenty plan ' + $verb + ' -r selfhost-container'
  } else {
    'corepack enable && yarn install --immutable && yarn twenty remote:add --as selfhost-container --url http://server:3000 --api-key "$TWENTY_API_KEY" && yarn twenty apply ' + $verb + ' -r selfhost-container'
  }
  & docker @cliArgs $command
  if ($LASTEXITCODE -ne 0) { throw "Twenty metadata $Action failed." }

  if ($Action -eq 'apply') {
    Write-Host 'Refreshing stateless runtime services after metadata apply...'
    Invoke-MahabbatCompose @('up', '-d', '--force-recreate', 'server', 'worker', 'pos-gateway')
    if (-not (Wait-MahabbatRuntime -TimeoutSeconds 240)) { throw 'Runtime health checks did not converge after metadata apply.' }
    Write-Host 'Metadata apply and stateless refresh complete. Run verify-runtime-api-parity before acceptance.'
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
