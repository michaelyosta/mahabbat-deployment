[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$privateDirectory = Join-Path $repoRoot '.private'
$privateKey = Join-Path $privateDirectory 'license-signing-ed25519.pem'
$publicKey = Join-Path $privateDirectory 'license-verification-public.pem'
if (Test-Path -LiteralPath $privateKey -PathType Leaf) {
  throw 'A signing key already exists. Refusing to replace it.'
}
New-Item -ItemType Directory -Force -Path $privateDirectory | Out-Null

$node = Get-Command node.exe,node -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) { throw 'Node.js is required on the private release workstation.' }
& $node.Source (Join-Path $PSScriptRoot 'license-cli.mjs') init --private-key $privateKey --public-key $publicKey
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the Ed25519 signing key.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $identity.User.Value
$directoryUserGrant = "*$($userSid):(OI)(CI)F"
$directorySystemGrant = '*S-1-5-18:(OI)(CI)F'
$directoryAdministratorsGrant = '*S-1-5-32-544:(OI)(CI)F'
& icacls.exe $privateDirectory /inheritance:r /grant:r $directoryUserGrant $directorySystemGrant $directoryAdministratorsGrant *> $null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to the private signing directory.' }

$fileUserGrant = "*$($userSid):(R,W)"
$fileSystemGrant = '*S-1-5-18:(R)'
$fileAdministratorsGrant = '*S-1-5-32-544:(R)'
& icacls.exe $privateKey /inheritance:r /grant:r $fileUserGrant $fileSystemGrant $fileAdministratorsGrant *> $null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to the signing key.' }
Write-Host 'Signing key initialized. Keep .private/license-signing-ed25519.pem offline and never include it in a release.'
