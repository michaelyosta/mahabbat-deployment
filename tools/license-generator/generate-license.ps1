[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Customer,
  [Parameter(Mandatory = $true)][string]$ActivationRequest,
  [ValidateRange(1, 365)][int]$Days = 30,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$toolRoot = $PSScriptRoot
$repoRoot = [IO.Path]::GetFullPath((Join-Path $toolRoot '..\..'))
$privateKey = Join-Path $repoRoot '.private\license-signing-ed25519.pem'
$activationPath = [IO.Path]::GetFullPath($ActivationRequest)
if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) {
  throw 'Private signing key is not initialized. Run initialize-license-signing.ps1 once on the release workstation.'
}
if (-not (Test-Path -LiteralPath $activationPath -PathType Leaf)) {
  throw 'Activation request file was not found.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $outputDirectory = Join-Path $repoRoot 'artifacts\licenses'
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
  $request = Get-Content -LiteralPath $activationPath -Raw | ConvertFrom-Json
  $OutputPath = Join-Path $outputDirectory ("mahabbat-{0}.license.json" -f $request.installation_id)
} else {
  $OutputPath = [IO.Path]::GetFullPath($OutputPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
}

$node = Get-Command node.exe,node -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) { throw 'Node.js is required on the private release workstation to sign a license.' }
& $node.Source (Join-Path $toolRoot 'license-cli.mjs') issue `
  --private-key $privateKey `
  --activation-request $activationPath `
  --customer $Customer `
  --days ([string]$Days) `
  --output $OutputPath
if ($LASTEXITCODE -ne 0) { throw 'License signing failed.' }

$licenseInfo = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
if ($licenseInfo.payload.customer -ne $Customer -or $licenseInfo.payload.duration_days -ne $Days) {
  Remove-Item -LiteralPath $OutputPath -Force
  throw 'Signed license failed its metadata validation.'
}
Write-Host "Ready: $OutputPath"
