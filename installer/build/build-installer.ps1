[CmdletBinding()]
param(
  [string]$NodeExe = '',
  [string]$NodeSha256 = '',
  [string]$NodeVersion = '',
  # Stage E: real distinguishable EXE versions (F14). Transitional 1.0.1 / 1.0.1.0,
  # candidate 1.1.0-rc.1 / 1.1.0.1. FileVersion MUST stay a numeric x.y.z.w quad.
  [string]$AppVersion = '1.0.0',
  [string]$FileVersion = '1.0.0.0'
)
if ($AppVersion -notmatch '^\d+\.\d+\.\d+(-rc\.\d+)?$') { throw "AppVersion must look like 1.0.1 or 1.1.0-rc.1, got '$AppVersion'." }
if ($FileVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "FileVersion must be a numeric x.y.z.w quad (e.g. 1.0.1.0), got '$FileVersion'." }

# Stage the controlled Node runtime for the Inno Setup build, then compile
# the setup EXE. Controlled source = official nodejs.org release archive
# (default v24.16.0 win-x64, version pinned in installer/app/runtime/NODE_VERSION.txt).
# -NodeExe stages a local node.exe instead of downloading (hash still verified
# when -NodeSha256 is given). Never commit a personal absolute path: the .iss
# references {#NodeSource} (the staged runtime copy), not your machine.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtimeDir = Join-Path $root 'installer\app\runtime'
$versionFile = Join-Path $runtimeDir 'NODE_VERSION.txt'
$defaultVersion = '24.16.0'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
  $fromFile = (Get-Content -Raw -LiteralPath $versionFile).Trim()
  if (-not [string]::IsNullOrWhiteSpace($fromFile)) { $defaultVersion = $fromFile }
}
if ([string]::IsNullOrWhiteSpace($NodeVersion)) { $NodeVersion = $defaultVersion }
if ($NodeVersion -notmatch '^\d+\.\d+\.\d+$') { throw "NodeVersion must look like 24.16.0, got '$NodeVersion'." }

$staged = Join-Path $runtimeDir 'node.exe'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

function Get-FileSha256([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose() }
  } finally { $sha.Dispose() }
}

if (-not [string]::IsNullOrWhiteSpace($NodeExe)) {
  if (-not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) { throw "NodeExe not found: $NodeExe" }
  Copy-Item -LiteralPath $NodeExe -Destination $staged -Force
  Write-Host "Staged local node.exe -> $staged"
} else {
  $zipName = "node-v$NodeVersion-win-x64.zip"
  $url = "https://nodejs.org/dist/v$NodeVersion/$zipName"
  $tmpZip = Join-Path ([IO.Path]::GetTempPath()) "mahabbat-$zipName"
  Write-Host "Downloading official Node $NodeVersion ($url) ..."
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmpZip
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "mahabbat-node-$NodeVersion"
    if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $tmpDir)
    $src = Join-Path $tmpDir "node-v$NodeVersion-win-x64\node.exe"
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw 'Official archive layout changed: node.exe not found.' }
    Copy-Item -LiteralPath $src -Destination $staged -Force
  } finally {
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Staged official node.exe $NodeVersion -> $staged"
}

$actual = Get-FileSha256 $staged
# Recorded hash of the node.exe staged on 2026-10-05 (official v24.16.0 win-x64).
$knownGood = 'b3094d0b49f9ad602262a9921551737bb97637c05dd357a06ae98188d7290aa3'
if (-not [string]::IsNullOrWhiteSpace($NodeSha256)) {
  if ($actual -ne $NodeSha256.Trim().ToLowerInvariant()) { throw "Staged node.exe SHA256 mismatch: got $actual." }
} elseif ($NodeVersion -eq '24.16.0') {
  if ($actual -ne $knownGood) {
    throw "Staged node.exe is NOT the known-good v24.16.0 binary (got $actual). Pass -NodeExe only with the official release, or update the known-good hash deliberately."
  }
} else {
  Write-Warning "No known-good hash recorded for Node $NodeVersion (got $actual). Pass -NodeSha256 to pin it, then record the value here."
}
[IO.File]::WriteAllText((Join-Path $runtimeDir 'NODE_SHA256.txt'), "$actual`n")
Write-Host "Node SHA256: $actual"

$iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) {
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd) { $iscc = $cmd.Source }
}
if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) { throw 'ISCC.exe (Inno Setup 6+) not found. Install Inno Setup, then re-run.' }
Write-Host "Building Mahabbat $AppVersion (file version $FileVersion) ..."
# ISCC /D defines override the .iss #ifndef fallbacks; OutputBaseFilename embeds AppVersion.
& $iscc "/DAppVersion=$AppVersion" "/DFileVersion=$FileVersion" (Join-Path $root 'installer\build\mahabbat-setup.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC build failed.' }
Write-Host 'Setup EXE built in installer/build/output/. Unsigned: see installer/UNLICENSED-SMARTSCREEN-NOTE.md.'
Write-Host "Expected output: installer/build/output/Mahabbat-Setup-$AppVersion.exe"
