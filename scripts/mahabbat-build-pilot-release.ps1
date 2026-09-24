[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InnerPath,
  [string]$NodeRuntimeRoot = (Join-Path $env:LOCALAPPDATA 'Temp\mahabbat-node-runtime\node-v24.16.0-win-x64'),
  [switch]$TwentyProductionSubscriptionConfirmed
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$innerRoot = [IO.Path]::GetFullPath($InnerPath)
$templateRoot = Join-Path $repoRoot 'deploy\pilot\package-template'
$artifactRoot = Join-Path $repoRoot 'artifacts\pilot-release'
$buildRoot = Join-Path $repoRoot 'artifacts\pilot-build'
$version = (Get-Content -LiteralPath (Join-Path $templateRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'The package VERSION must be a plain semantic version.' }

function Assert-PilotCommandSuccess {
  param([Parameter(Mandatory = $true)][string]$Name)
  if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
}

function Copy-RequiredFile {
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required release input is missing: $Source" }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination
}

function Get-OfficialTextFile {
  param([Parameter(Mandatory = $true)][uri]$Uri, [Parameter(Mandatory = $true)][string]$Destination, [Parameter(Mandatory = $true)][string]$ExpectedText)
  $temporary = "$Destination.$([Guid]::NewGuid().ToString('N')).part"
  try {
    Invoke-WebRequest -Uri $Uri -OutFile $temporary -TimeoutSec 60
    $text = Get-Content -LiteralPath $temporary -Raw
    if ($text -notmatch [regex]::Escape($ExpectedText)) { throw "Official license content did not match expectations: $Uri" }
    Move-Item -LiteralPath $temporary -Destination $Destination
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
}

if (-not (Test-Path -LiteralPath $innerRoot -PathType Container)) { throw "Inner repository not found: $innerRoot" }
$innerLock = Get-Content -LiteralPath (Join-Path $repoRoot 'mahabbat-inner.lock.json') -Raw | ConvertFrom-Json
$innerHead = ((& git -C $innerRoot rev-parse HEAD 2>$null) -join '').Trim()
Assert-PilotCommandSuccess 'Reading inner HEAD'
if ($innerHead -cne [string]$innerLock.commit) { throw "Inner HEAD does not match mahabbat-inner.lock.json ($innerHead != $($innerLock.commit))." }
if ((& git -C $innerRoot status --porcelain 2>$null) -join '') { throw 'Refusing to package a dirty inner application worktree.' }
$innerPackage = Get-Content -LiteralPath (Join-Path $innerRoot 'package.json') -Raw | ConvertFrom-Json
if ($innerPackage.version -cne $version) { throw "Package version $version differs from inner application version $($innerPackage.version)." }

$nodeExe = Join-Path $NodeRuntimeRoot 'node.exe'
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) { throw "Bundled Node runtime is missing: $nodeExe" }
$nodeVersion = (& $nodeExe --version 2>$null | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -ne 'v24.16.0') { throw "Expected bundled Node v24.16.0; got $nodeVersion." }
$nodeSignature = Get-AuthenticodeSignature -FilePath $nodeExe
if ($nodeSignature.Status -ne 'Valid') { throw "Bundled Node executable signature is not valid: $($nodeSignature.Status)." }

$vitestCli = Join-Path $innerRoot 'node_modules\vitest\vitest.mjs'
if (-not (Test-Path -LiteralPath $vitestCli -PathType Leaf)) { throw 'The locked inner worktree is missing its test runtime; install immutable dependencies before release.' }
Push-Location $innerRoot
try {
  & $nodeExe $vitestCli run --config vitest.unit.config.ts
  Assert-PilotCommandSuccess 'Mahabbat unit suite'
  foreach ($testFile in @('pos-standalone\server\__tests__\gateway.test.mjs', 'pos-standalone\server\__tests__\printing.test.mjs', 'pos-standalone\server\__tests__\print-gateway.test.mjs')) {
    & $nodeExe --test $testFile
    Assert-PilotCommandSuccess "Mahabbat regression $testFile"
  }
} finally { Pop-Location }

$gatewayTests = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deploy\pilot\license-gateway\test') -Filter '*.test.mjs' -File | Select-Object -ExpandProperty FullName)
& $nodeExe --test @gatewayTests
Assert-PilotCommandSuccess 'Pilot license-gateway tests'
$licenseCliTest = Join-Path $repoRoot 'tools\license-generator\license-cli.test.mjs'
& $nodeExe --test $licenseCliTest
Assert-PilotCommandSuccess 'Pilot license-generator tests'

$publicKey = Join-Path $repoRoot '.private\license-verification-public.pem'
$privateKey = Join-Path $repoRoot '.private\license-signing-ed25519.pem'
if (-not (Test-Path -LiteralPath $publicKey -PathType Leaf) -or -not (Test-Path -LiteralPath $privateKey -PathType Leaf)) {
  throw 'The local Ed25519 license key pair is missing. The private key must remain in .private and outside the release.'
}

$imagesArchive = Join-Path $buildRoot 'mahabbat-runtime-images.tar'
$imagesManifestPath = Join-Path $buildRoot 'images-manifest.json'
if (-not (Test-Path -LiteralPath $imagesArchive -PathType Leaf) -or -not (Test-Path -LiteralPath $imagesManifestPath -PathType Leaf)) {
  throw 'Build the locked runtime images first with scripts\pilot-build-images.ps1.'
}
$imagesManifest = Get-Content -LiteralPath $imagesManifestPath -Raw | ConvertFrom-Json
if ([int]$imagesManifest.schema_version -ne 1 -or [string]$imagesManifest.inner_commit -cne $innerHead -or @($imagesManifest.images).Count -lt 5) {
  throw 'Runtime image manifest is stale, malformed, or does not match the locked inner commit.'
}
foreach ($image in $imagesManifest.images) {
  $actualId = (& docker.exe image inspect ([string]$image.reference) --format '{{.Id}}' 2>$null | Select-Object -First 1)
  if ($LASTEXITCODE -ne 0 -or ([string]$actualId).Trim() -cne [string]$image.imageId) {
    throw "Runtime image does not match the saved manifest: $($image.reference). Rebuild the images."
  }
}

$appTarball = Join-Path $innerRoot ('.twenty\output\mahabbat-{0}.tgz' -f $version)
if (-not (Test-Path -LiteralPath $appTarball -PathType Leaf)) { throw "Compiled Twenty application tarball is missing: $appTarball" }
$tarFiles = @(& tar.exe -tzf $appTarball 2>$null)
Assert-PilotCommandSuccess 'Inspecting compiled application tarball'
if ($tarFiles.Count -lt 10 -or $tarFiles -notcontains 'package/manifest.json' -or @($tarFiles | Where-Object { $_ -match '\.(ts|tsx|map)$|(^|/)\.env($|\.)|(^|/)node_modules/' }).Count -gt 0) {
  throw 'Compiled application package is incomplete or contains development/source artifacts.'
}

$appInstaller = Join-Path $buildRoot 'mahabbat-app-installer.mjs'
& $nodeExe (Join-Path $repoRoot 'tools\build-pilot-app-installer.mjs') $innerRoot $appInstaller
Assert-PilotCommandSuccess 'Building bundled app installer'
$appInstallerLegal = "$appInstaller.LEGAL.txt"
if (-not (Test-Path -LiteralPath $appInstallerLegal -PathType Leaf) -or (Get-Item -LiteralPath $appInstallerLegal).Length -eq 0) {
  throw 'Bundled SDK installer has no external legal-notices file.'
}

$upstream = Get-Content -LiteralPath (Join-Path $repoRoot 'upstream-twenty.lock.json') -Raw | ConvertFrom-Json
$nodeLicenseCache = Join-Path $buildRoot 'third-party\node-v24.16.0-LICENSE.txt'
$twentyLicenseCache = Join-Path $buildRoot ('third-party\twenty-{0}-LICENSE.txt' -f ([string]$upstream.commit).Substring(0, 12))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nodeLicenseCache) | Out-Null
if (-not (Test-Path -LiteralPath $nodeLicenseCache -PathType Leaf)) {
  Get-OfficialTextFile -Uri 'https://raw.githubusercontent.com/nodejs/node/v24.16.0/LICENSE' -Destination $nodeLicenseCache -ExpectedText 'Node.js is licensed for use as follows:'
}
if (-not (Test-Path -LiteralPath $twentyLicenseCache -PathType Leaf)) {
  $twentyLicenseUri = [uri]('https://raw.githubusercontent.com/twentyhq/twenty/{0}/LICENSE' -f $upstream.commit)
  Get-OfficialTextFile -Uri $twentyLicenseUri -Destination $twentyLicenseCache -ExpectedText 'The Twenty.com Commercial License'
}

$stageParent = Join-Path $artifactRoot 'staging'
New-Item -ItemType Directory -Force -Path $stageParent | Out-Null
$stage = Join-Path $stageParent ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$buildingZip = Join-Path $artifactRoot ('Mahabbat-v{0}-pilot-{1}.building.zip' -f $version, [Guid]::NewGuid().ToString('N'))
$releaseName = if ($TwentyProductionSubscriptionConfirmed) { "Mahabbat-v$version-pilot.zip" } else { "Mahabbat-v$version-pilot-REVIEW-ONLY.zip" }
$releasePath = Join-Path $artifactRoot $releaseName
if (Test-Path -LiteralPath $releasePath) { throw "Refusing to overwrite an existing release artifact: $releasePath" }

try {
  foreach ($directory in @('app', 'license', 'runtime\node', 'runtime\print-gateway', 'runtime\installer', 'licenses', 'scripts')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage $directory) | Out-Null
  }

  foreach ($script in @('install.ps1', 'install-app.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'doctor.ps1', 'backup.ps1', 'restore.ps1', 'update.ps1', 'activation-request.ps1', 'activate.ps1')) {
    Copy-RequiredFile (Join-Path $templateRoot $script) (Join-Path $stage $script)
  }
  Copy-RequiredFile (Join-Path $templateRoot 'scripts\pilot-common.ps1') (Join-Path $stage 'scripts\pilot-common.ps1')
  Copy-RequiredFile (Join-Path $repoRoot 'deploy\pilot\compose.yaml') (Join-Path $stage 'compose.yaml')
  Copy-RequiredFile (Join-Path $templateRoot 'VERSION') (Join-Path $stage 'VERSION')
  Copy-RequiredFile (Join-Path $templateRoot 'README.txt') (Join-Path $stage 'README.txt')
  Copy-RequiredFile $imagesArchive (Join-Path $stage 'runtime-images.tar')
  Copy-RequiredFile $imagesManifestPath (Join-Path $stage 'image-manifest.json')
  Copy-RequiredFile $publicKey (Join-Path $stage 'license\public-key.pem')
  Copy-RequiredFile $nodeExe (Join-Path $stage 'runtime\node\node.exe')
  Copy-RequiredFile $nodeLicenseCache (Join-Path $stage 'licenses\Node-LICENSE.txt')
  Copy-RequiredFile $twentyLicenseCache (Join-Path $stage 'licenses\Twenty-LICENSE.txt')
  Copy-RequiredFile (Join-Path $repoRoot 'deploy\mahabbat-branding.Dockerfile') (Join-Path $stage 'licenses\mahabbat-branding.Dockerfile')
  Copy-RequiredFile (Join-Path $repoRoot 'deploy\branding-overlay.mjs') (Join-Path $stage 'licenses\branding-overlay.mjs')
  Copy-RequiredFile $appTarball (Join-Path $stage ('app\mahabbat-{0}.tgz' -f $version))
  Copy-RequiredFile $appInstaller (Join-Path $stage 'runtime\installer\mahabbat-app-installer.mjs')
  Copy-RequiredFile $appInstallerLegal (Join-Path $stage 'runtime\installer\mahabbat-app-installer.mjs.LEGAL.txt')
  foreach ($file in @('print-gateway.mjs', 'escpos.mjs', 'printer-transport.mjs', 'windows-printer-provider.mjs')) {
    Copy-RequiredFile (Join-Path $innerRoot (Join-Path 'pos-standalone\server' $file)) (Join-Path $stage (Join-Path 'runtime\print-gateway' $file))
  }

  $appExtractRoot = Join-Path $stage 'app'
  & tar.exe -xzf (Join-Path $stage ('app\mahabbat-{0}.tgz' -f $version)) -C $appExtractRoot
  Assert-PilotCommandSuccess 'Extracting compiled application metadata'
  $unpackedPath = Join-Path $appExtractRoot 'package'
  if (-not (Test-Path -LiteralPath (Join-Path $unpackedPath 'manifest.json') -PathType Leaf)) { throw 'Compiled application manifest was not extracted.' }
  Move-Item -LiteralPath $unpackedPath -Destination (Join-Path $appExtractRoot 'unpacked')

  $releaseStatus = if ($TwentyProductionSubscriptionConfirmed) {
    "Release operator confirmed the required Twenty Enterprise production subscription for this deployment. This package does not contain or grant that subscription.`n"
  } else {
    "REVIEW ONLY — DO NOT DEPLOY TO A RESTAURANT OR USE IN PRODUCTION.`nThe pinned Twenty image contains and loads Enterprise-licensed modules. Production use requires a valid Twenty Enterprise subscription or other written authorization. This archive is for isolated technical testing only.`n"
  }
  [IO.File]::WriteAllText((Join-Path $stage 'licenses\RELEASE-STATUS.txt'), $releaseStatus, [Text.UTF8Encoding]::new($false))
  $sourceNotice = @"
Mahabbat pilot dependency notices
=================================

Node.js v24.16.0: see Node-LICENSE.txt.
Twenty v2.29.0, commit $($upstream.commit): see Twenty-LICENSE.txt.
Pinned upstream: https://github.com/twentyhq/twenty/tree/$($upstream.commit)
The deployment branding overlay is included as mahabbat-branding.Dockerfile and branding-overlay.mjs.
The compiled Mahabbat application was built using the official Twenty app tooling; the included .LEGAL.txt contains notices preserved from the bundled SDK installer.
Docker Desktop is a separate prerequisite and is not included in this archive.

The release operator must separately meet all applicable upstream license and subscription terms before production use.
"@
  [IO.File]::WriteAllText((Join-Path $stage 'licenses\THIRD-PARTY-NOTICES.txt'), $sourceNotice, [Text.UTF8Encoding]::new($false))

  $testConfiguration = Join-Path $repoRoot 'deploy\pilot\private.env.example'
  & docker.exe compose --file (Join-Path $stage 'compose.yaml') --env-file $testConfiguration config --quiet *> $null
  Assert-PilotCommandSuccess 'Validating pilot compose configuration'
  foreach ($scriptFile in Get-ChildItem -LiteralPath $stage -Filter '*.ps1' -Recurse -File) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "PowerShell syntax error in packaged script $($scriptFile.Name): $($parseErrors[0].Message)" }
  }
  foreach ($scriptFile in @((Join-Path $stage 'runtime\print-gateway\print-gateway.mjs'), (Join-Path $stage 'runtime\installer\mahabbat-app-installer.mjs'))) {
    & $nodeExe --check $scriptFile
    Assert-PilotCommandSuccess "Checking packaged JavaScript $([IO.Path]::GetFileName($scriptFile))"
  }

  $imageRecords = @($imagesManifest.images | ForEach-Object { [ordered]@{ reference = $_.reference; image_id = $_.imageId } })
  $payloadFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($stage.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)).Replace('\', '/')
    [ordered]@{ path = $relative; size_bytes = [long]$_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
  })
  $releaseManifest = [ordered]@{
    schema_version = 1
    product = 'Mahabbat'
    version = $version
    build = '{0}+{1}' -f (Get-Date -Format 'yyyyMMdd'), $innerHead.Substring(0, 12)
    created_at = [DateTime]::UtcNow.ToString('o')
    inner_commit = $innerHead
    upstream_twenty_commit = [string]$upstream.commit
    image_archive_sha256 = (Get-FileHash -LiteralPath (Join-Path $stage 'runtime-images.tar') -Algorithm SHA256).Hash.ToLowerInvariant()
    images = $imageRecords
    files = $payloadFiles
  }
  [IO.File]::WriteAllText((Join-Path $stage 'release-manifest.json'), ($releaseManifest | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($stage, $buildingZip, [IO.Compression.CompressionLevel]::Optimal, $false)
  $zip = [IO.Compression.ZipFile]::OpenRead($buildingZip)
  try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    $required = @('VERSION', 'README.txt', 'install.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'backup.ps1', 'restore.ps1', 'update.ps1', 'doctor.ps1', 'install-app.ps1', 'compose.yaml', 'runtime-images.tar', 'image-manifest.json', 'license/public-key.pem', 'release-manifest.json')
    foreach ($entry in $required) { if ($names -notcontains $entry) { throw "ZIP self-test failed: missing $entry" } }
    foreach ($name in $names) {
      $segments = $name -split '/'
      if (($segments -contains '.git') -or ($segments -contains '.private') -or ($segments -contains 'node_modules') -or $name -match '(^|/)\.env($|\.)|(^|/)id_(rsa|ed25519)(\.|$)|license-signing-ed25519|\.(ts|tsx|map|pdb)$|(^|/)yarn\.lock$|(^|/)package-lock\.json$') {
        throw "ZIP self-test failed: forbidden development or secret file $name"
      }
      if ($name -match '\.pem$' -and $name -ne 'license/public-key.pem') { throw "ZIP self-test failed: unexpected PEM file $name" }
    }
    $zipManifestEntry = $zip.GetEntry('release-manifest.json')
    $zipReader = [IO.StreamReader]::new($zipManifestEntry.Open())
    try { $zipManifest = $zipReader.ReadToEnd() | ConvertFrom-Json } finally { $zipReader.Dispose() }
    if ([string]$zipManifest.inner_commit -cne $innerHead -or @($zipManifest.files).Count -ne $payloadFiles.Count) { throw 'ZIP self-test failed: release manifest metadata mismatch.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
    foreach ($file in $zipManifest.files) {
      $entry = $zip.GetEntry([string]$file.path)
      if ($null -eq $entry -or [long]$entry.Length -ne [long]$file.size_bytes) { throw "ZIP self-test failed: missing or wrong-sized payload $($file.path)" }
        $entryStream = $entry.Open()
        try { $entryHash = ([BitConverter]::ToString($sha.ComputeHash($entryStream))).Replace('-', '').ToLowerInvariant() } finally { $entryStream.Dispose() }
        if ($entryHash -cne [string]$file.sha256) { throw "ZIP self-test failed: checksum mismatch for $($file.path)" }
      }
    } finally {
      $sha.Dispose()
    }
  } finally { $zip.Dispose() }

  Move-Item -LiteralPath $buildingZip -Destination $releasePath
  $archive = Get-Item -LiteralPath $releasePath
  $sha256 = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "Release archive: $releasePath"
  Write-Host ('Archive bytes: {0:N0}' -f $archive.Length)
  Write-Host "Archive SHA256: $sha256"
  Write-Host "INNER_COMMIT=$innerHead"
  Write-Host "TWENTY_UPSTREAM=$($upstream.commit)"
  Write-Host "PACKAGE_STATUS=$(if($TwentyProductionSubscriptionConfirmed){'PRODUCTION_SUBSCRIPTION_CONFIRMED_BY_OPERATOR'}else{'REVIEW_ONLY_TWENTY_ENTERPRISE_LICENSE_REQUIRED'})"
  Write-Host 'PILOT_RELEASE_PACKAGE_SELF_TEST=PASS'
} finally {
  if (Test-Path -LiteralPath $buildingZip) { Remove-Item -LiteralPath $buildingZip -Force }
  if (Test-Path -LiteralPath $stage) {
    $fullStage = [IO.Path]::GetFullPath($stage)
    $safePrefix = [IO.Path]::GetFullPath($stageParent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullStage.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a release staging path outside artifacts.' }
    Remove-Item -LiteralPath $fullStage -Recurse -Force
  }
}
