[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InnerPath,
  [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$innerRoot = [IO.Path]::GetFullPath($InnerPath)
$innerLock = Get-Content -LiteralPath (Join-Path $repoRoot 'mahabbat-inner.lock.json') -Raw | ConvertFrom-Json
$actualInner = ((& git -C $innerRoot rev-parse HEAD 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $actualInner -ne $innerLock.commit) {
  throw "Inner source must match lock $($innerLock.commit); got $actualInner."
}
if ((& git -C $innerRoot status --porcelain 2>$null) -join '') { throw 'Refusing to build a release from a dirty inner worktree.' }

$images = @(
  'mahabbat-twenty:v2.29.0-branding-pilot0.9.0',
  'mahabbat-pos-gateway:v0.9.0',
  'mahabbat-license-gateway:v0.9.0',
  'postgres:16-alpine',
  'redis:7-alpine'
)
$artifactDir = Join-Path $repoRoot 'artifacts\pilot-build'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$stage = Join-Path $artifactDir 'pos-context'
if (Test-Path -LiteralPath $stage) { throw "Build staging directory already exists; remove it manually after confirming it is only generated output: $stage" }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'pos-standalone\web') | Out-Null

try {
  foreach ($relative in @('src', 'pos-standalone\server', 'pos-standalone\web\src')) {
    Copy-Item -LiteralPath (Join-Path $innerRoot $relative) -Destination (Join-Path $stage $relative) -Recurse
  }
  foreach ($file in @('pos-standalone\Dockerfile', 'pos-standalone\web\package.json', 'pos-standalone\web\package-lock.json', 'pos-standalone\web\index.html', 'pos-standalone\web\vite.config.ts')) {
    $destination = Join-Path $stage $file
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $innerRoot $file) -Destination $destination
  }

  foreach ($base in @('postgres:16-alpine', 'redis:7-alpine', 'twentycrm/twenty:v2.29.0', 'node:24-alpine')) {
    & docker image inspect $base *> $null
    if ($LASTEXITCODE -ne 0) {
      & docker pull $base
      if ($LASTEXITCODE -ne 0) { throw "Could not pull required base image $base." }
    }
  }

  & docker build --pull=false -f deploy\mahabbat-branding.Dockerfile -t $images[0] .
  if ($LASTEXITCODE -ne 0) { throw 'Twenty branding image build failed.' }
  & docker build --pull=false -f (Join-Path $stage 'pos-standalone\Dockerfile') -t $images[1] $stage
  if ($LASTEXITCODE -ne 0) { throw 'Standalone POS image build failed.' }
  & docker build --pull=false -f deploy\pilot\license-gateway\Dockerfile -t $images[2] deploy\pilot\license-gateway
  if ($LASTEXITCODE -ne 0) { throw 'License gateway image build failed.' }

$imageEntries = @(foreach ($image in $images) {
    $inspect = & docker image inspect $image --format '{{.Id}}|{{.Created}}|{{.Size}}'
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect image $image." }
    $parts = $inspect -split '\|', 3
    [ordered]@{ reference = $image; imageId = $parts[0]; created = $parts[1]; sizeBytes = [long]$parts[2] }
  })
$manifest = [ordered]@{
  schema_version = 1
  inner_commit = $actualInner
  generated_at = [DateTime]::UtcNow.ToString('o')
  images = $imageEntries
}
  $manifestPath = Join-Path $artifactDir 'images-manifest.json'
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

  if (-not $SkipArchive) {
    $archivePath = Join-Path $artifactDir 'mahabbat-runtime-images.tar'
    & docker save --output $archivePath @images
    if ($LASTEXITCODE -ne 0) { throw 'Docker image archive creation failed.' }
    Write-Host "Image archive: $archivePath"
    Write-Host ('Archive bytes: {0:N0}' -f (Get-Item -LiteralPath $archivePath).Length)
  }
  Write-Host "Inner source: $actualInner"
  Write-Host 'PILOT_IMAGE_BUILD=PASS'
} finally {
  if (Test-Path -LiteralPath $stage) {
    $fullStage = [IO.Path]::GetFullPath($stage)
    $fullArtifactDir = [IO.Path]::GetFullPath($artifactDir)
    if (-not $fullStage.StartsWith($fullArtifactDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Unsafe build staging cleanup path.'
    }
    Remove-Item -LiteralPath $fullStage -Recurse -Force
  }
}
