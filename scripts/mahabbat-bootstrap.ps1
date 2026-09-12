[CmdletBinding()]
param(
  [switch]$Build
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

function New-MahabbatRandomHex {
  param([int]$ByteCount = 32)
  $bytes = New-Object byte[] $ByteCount
  [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

try {
  $root = Get-MahabbatRoot
  Assert-MahabbatCommand 'git'
  Assert-MahabbatCommand 'docker'

  $dataStatusPath = Join-Path $root 'legacy-data-status.json'
  if (-not (Test-Path -LiteralPath $dataStatusPath -PathType Leaf)) {
    throw 'legacy-data-status.json is missing; establish legacy data status before bootstrapping.'
  }
  $dataStatus = Get-Content -Raw -LiteralPath $dataStatusPath | ConvertFrom-Json
  if ([string]$dataStatus.status -notin @('UNAVAILABLE', 'RECOVERED', 'PARTIALLY RECOVERED')) {
    throw 'legacy data status is not explicit; refusing to bootstrap.'
  }

  $lock = Get-MahabbatLock
  $innerPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$lock.expectedLocalPath)))
  if (-not (Test-Path -LiteralPath $innerPath -PathType Container)) {
    Write-Host 'Fetching canonical Mahabbat inner repository...'
    & git clone --no-checkout ([string]$lock.repository) $innerPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone the canonical inner repository.' }
  }

  $dirty = ((& git -C $innerPath status --porcelain 2>$null) -join '').Trim()
  if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    throw 'Inner repository is dirty; refusing to change its checkout.'
  }
  & git -C $innerPath fetch --prune origin
  if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the canonical inner repository.' }
  & git -C $innerPath checkout --detach ([string]$lock.commit)
  if ($LASTEXITCODE -ne 0) { throw "Could not checkout locked inner SHA $($lock.commit)." }

  $envPath = Join-Path $root '.env'
  $envCreated = $false
  if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    $envText = @"
PG_DATABASE_USER=postgres
PG_DATABASE_PASSWORD=$(New-MahabbatRandomHex 24)
PG_DATABASE_NAME=default
PG_DATABASE_HOST=db
PG_DATABASE_PORT=5432
SERVER_URL=http://localhost:3000
REDIS_URL=redis://redis:6379
STORAGE_TYPE=local
LOGIC_FUNCTION_TYPE=LOCAL
ENCRYPTION_KEY=$(New-MahabbatRandomHex 32)
FALLBACK_ENCRYPTION_KEY=
APP_SECRET=$(New-MahabbatRandomHex 32)
MAHABBAT_INTERNAL_ROUTE_SECRET=$(New-MahabbatRandomHex 32)
FRONT_AUTO_BASE_URL=true
TWENTY_API_KEY=
MAHABBAT_API_KEY=
TWENTY_APP_ACCESS_TOKEN=
POS_GATEWAY_PORT=3100
POS_CORS_ORIGIN=*
MAHABBAT_POS_SEED_WAITER_PIN=
MAHABBAT_POS_SEED_ADMIN_PIN=
MAHABBAT_POS_PIN_A=
MAHABBAT_POS_PIN_B=
MAHABBAT_POS_SESSION_IDLE_MINUTES=15
"@
    [IO.File]::WriteAllText($envPath, $envText.TrimStart())
    $envCreated = $true
  }

  Assert-MahabbatDockerEngine
  if (-not (Test-MahabbatComposeConfig)) { throw 'docker compose config validation failed.' }
  if ($Build) { Invoke-MahabbatCompose @('build') }

  $inner = Get-MahabbatInnerState
  Write-Host 'MAHABBAT BOOTSTRAP'
  Write-Host "Inner: $($inner.Actual) (LOCK MATCH: $($inner.Match))"
  Write-Host (".env: {0}" -f ($(if ($envCreated) { 'created locally; secrets not displayed' } else { 'preserved' })))
  Write-Host "Legacy data: $($dataStatus.status)"
  Write-Host 'Next: .\scripts\mahabbat-start.ps1'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
