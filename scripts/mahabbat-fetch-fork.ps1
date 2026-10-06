[CmdletBinding()]
param(
  [string]$ForkDir = '',
  [string]$Ref = 'twenty/v2.29.0'
)

<#
.SYNOPSIS
  Materialize the Mahabbat Twenty fork (sparse upstream checkout + patches).

  The fork is NOT vendored in git. This script clones twentyhq/twenty at the
  pinned tag, applies the sparse paths, and stamps the resolved commit into
  mahabbat-twenty.lock.json. Run once per venue PC before the first build.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ForkDir)) { $ForkDir = Join-Path $root 'mahabbat-twenty' }
$lockPath = Join-Path $root 'mahabbat-twenty.lock.json'

$upstreamRepo = 'https://github.com/twentyhq/twenty.git'
$sparsePaths = @(
  'packages/twenty-server/src/database/commands',
  'packages/twenty-server/src/engine/core-modules/api-key',
  'packages/twenty-server/src/engine/core-modules/auth',
  'packages/twenty-server/src/engine/core-modules/user',
  'packages/twenty-server/src/engine/core-modules/user-workspace',
  'packages/twenty-server/src/engine/core-modules/workspace',
  'packages/twenty-server/src/engine/guards',
  'packages/twenty-server/src/engine/core-modules/captcha',
  'packages/twenty-shared/src/metadata',
  'packages/twenty-shared/src/translations',
  'packages/twenty-shared/src/utils',
  'packages/twenty-server/package.json'
)

if (-not (Test-Path -LiteralPath $ForkDir -PathType Container)) {
  Write-Host "Cloning Twenty $Ref (sparse)..."
  & git clone --depth 1 --branch $Ref --single-branch --no-checkout $upstreamRepo $ForkDir
  if ($LASTEXITCODE -ne 0) { throw 'Could not clone twentyhq/twenty.' }
  Push-Location $ForkDir
  try {
    & git sparse-checkout init --cone 2>$null
    & git sparse-checkout set @sparsePaths
    if ($LASTEXITCODE -ne 0) { throw 'Sparse checkout setup failed.' }
    & git checkout 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Sparse checkout failed.' }
  } finally { Pop-Location }
}

Push-Location $ForkDir
try {
  $commit = ((& git rev-parse HEAD 2>$null) -join '').Trim()
} finally { Pop-Location }
if ([string]::IsNullOrWhiteSpace($commit)) { throw 'Could not resolve fork base commit.' }

$lock = [ordered]@{
  repository = $upstreamRepo
  ref = $Ref
  commit = $commit
  patches = @(
    'packages/twenty-server/src/database/commands/workspace-bootstrap-venue.command.ts',
    'packages/twenty-server/src/database/commands/database-command.module.ts',
    'packages/twenty-server/src/engine/core-modules/api-key/commands/generate-api-key.command.ts'
  )
  note = 'Mahabbat fork: headless venue bootstrap. Re-apply patches on rebase; see mahabbat-twenty/MAHABBAT_FORK.md (kept outside git).'
}
[IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 5) + "`n"))
Write-Host "Fork ready at $ForkDir ($commit). Lock written to mahabbat-twenty.lock.json."
