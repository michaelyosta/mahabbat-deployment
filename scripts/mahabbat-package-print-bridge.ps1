[CmdletBinding()]
param(
  [string]$RemoteUrl = 'https://crm-pilot.showalove.ru',
  [string]$EnvFile = '',
  [string]$GatewayId = 'restaurant-soft-group-8256',
  [string]$OutputDirectory = '',
  [string]$NodePath = '',
  [switch]$SkipSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$innerPath = Join-Path $root 'mahabbat-app'
$sourcePath = Join-Path $root 'deploy\print-bridge'
if ([string]::IsNullOrWhiteSpace($EnvFile)) { $EnvFile = Join-Path $root '.env' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'artifacts\print-bridge' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path $OutputDirectory 'Mahabbat-Print-Bridge-v1'
$zipPath = Join-Path $OutputDirectory 'Mahabbat-Print-Bridge-v1-private.zip'
$tempTestPackage = Join-Path ([IO.Path]::GetTempPath()) ('Mahabbat Print Bridge Self Test ' + [guid]::NewGuid().ToString('N'))

function Read-EnvMap {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Environment file is missing: $Path" }
  $map = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
      $value = $matches[2]
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) { $value = $value.Substring(1, $value.Length - 2) }
      $map[$matches[1]] = $value
    }
  }
  return $map
}

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Copy-Required {
  param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required package source is missing: $Source" }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-EnvValue {
  param([Parameter(Mandatory = $true)][hashtable]$EnvMap, [Parameter(Mandatory = $true)][string]$Name)
  if ($EnvMap.ContainsKey($Name)) { return [string]$EnvMap[$Name] }
  return ''
}

function Get-OptionalRemoteRows {
  param([Parameter(Mandatory = $true)][hashtable]$EnvMap, [Parameter(Mandatory = $true)][string]$Name)
  $url = Get-EnvValue $EnvMap 'SERVER_URL'
  $key = Get-EnvValue $EnvMap 'TWENTY_API_KEY'
  if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key) -or $key.StartsWith('<')) { return @() }
  try {
    $snapshotUrl = $url.TrimEnd('/')
    if ($snapshotUrl -match '^http://localhost(?::|/|$)') { $snapshotUrl = $snapshotUrl -replace '^http://localhost', 'http://127.0.0.1' }
    $response = Invoke-RestMethod -UseBasicParsing -Uri "$snapshotUrl/rest/$Name`?limit=200" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 8 -ErrorAction Stop
    $property = switch ($Name) { 'posProductionStations' { 'posProductionStations' } 'posPrinterDevices' { 'posPrinterDevices' } default { $Name } }
    return @($response.data.$property)
  } catch {
    Write-Warning "Could not snapshot $Name from the local workspace; the package will still run without that optional list."
    return @()
  }
}

try {
  if (-not (Test-Path -LiteralPath $innerPath -PathType Container)) { throw "Inner repository is missing at $innerPath. Run mahabbat-bootstrap.ps1 first." }
  if (-not ($RemoteUrl -match '^https://[^/?#]+(?:/[^?#]*)?$')) { throw 'RemoteUrl must be an HTTPS origin without query parameters.' }
  $envMap = Read-EnvMap $EnvFile
  $routeSecret = Get-EnvValue $envMap 'MAHABBAT_INTERNAL_ROUTE_SECRET'
  if ([string]::IsNullOrWhiteSpace($routeSecret) -or $routeSecret.StartsWith('<')) { throw 'MAHABBAT_INTERNAL_ROUTE_SECRET is missing from the private environment.' }
  $nvmrcPath = Join-Path $innerPath '.nvmrc'
  if (-not (Test-Path -LiteralPath $nvmrcPath -PathType Leaf)) { throw "Canonical Node version file is missing: $nvmrcPath" }
  $requiredNodeVersion = (Get-Content -LiteralPath $nvmrcPath -Raw).Trim()
  if ($requiredNodeVersion.StartsWith('v')) { $requiredNodeVersion = $requiredNodeVersion.Substring(1) }
  if ($requiredNodeVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid canonical Node version in $nvmrcPath" }
  if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $nodeCommand = Get-Command node -ErrorAction Stop
    $NodePath = $nodeCommand.Source
  }
  if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node runtime is missing: $NodePath" }
  $nodeVersion = (& $NodePath --version).Trim()
  if ($nodeVersion -ne "v$requiredNodeVersion") {
    throw "Bundled Node must match canonical .nvmrc v$requiredNodeVersion; received $nodeVersion. Pass -NodePath to the matching node.exe."
  }
  $runtimeSha256 = (Get-FileHash -LiteralPath $NodePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $innerSha = ((& git -C $innerPath rev-parse HEAD 2>$null) -join '').Trim()
  if ([string]::IsNullOrWhiteSpace($innerSha)) { throw 'Could not resolve the canonical inner SHA.' }

  $targets = @(
    @{ Source = Join-Path $sourcePath 'bridge-app.mjs'; Destination = Join-Path $stage 'bridge-app.mjs' },
    @{ Source = Join-Path $sourcePath 'Mahabbat Print Bridge.vbs'; Destination = Join-Path $stage 'Mahabbat Print Bridge.vbs' },
    @{ Source = Join-Path $sourcePath 'RESTAURANT_PRINT_QUICKSTART.txt'; Destination = Join-Path $stage 'RESTAURANT_PRINT_QUICKSTART.txt' },
    @{ Source = Join-Path $innerPath 'pos-standalone\server\print-gateway.mjs'; Destination = Join-Path $stage 'gateway\print-gateway.mjs' },
    @{ Source = Join-Path $innerPath 'pos-standalone\server\escpos.mjs'; Destination = Join-Path $stage 'gateway\escpos.mjs' },
    @{ Source = Join-Path $innerPath 'pos-standalone\server\printer-transport.mjs'; Destination = Join-Path $stage 'gateway\printer-transport.mjs' },
    @{ Source = Join-Path $innerPath 'pos-standalone\server\windows-printer-provider.mjs'; Destination = Join-Path $stage 'gateway\windows-printer-provider.mjs' }
  )

  New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
  if (Test-Path -LiteralPath $stage) {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
    if (-not $resolvedStage.StartsWith($resolvedOutput + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a staging path outside the output directory.' }
    Remove-Item -LiteralPath $stage -Recurse -Force
  }
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'config'), (Join-Path $stage 'data'), (Join-Path $stage 'logs'), (Join-Path $stage 'runtime') | Out-Null
  foreach ($target in $targets) { Copy-Required $target.Source $target.Destination }
  Copy-Required $NodePath (Join-Path $stage 'runtime\node.exe')
  Copy-Required (Join-Path (Split-Path $NodePath -Parent) 'LICENSE') (Join-Path $stage 'runtime\NODE-LICENSE.txt')

  $accessId = Get-EnvValue $envMap 'CLOUDFLARE_ACCESS_CLIENT_ID'
  $accessSecret = Get-EnvValue $envMap 'CLOUDFLARE_ACCESS_CLIENT_SECRET'
  $configLines = @(
    '# Private configuration for one restaurant bridge. Do not publish this file.',
    "TWENTY_API_URL=$RemoteUrl",
    'PRINT_GATEWAY_MODE=REMOTE',
    "MAHABBAT_INTERNAL_ROUTE_SECRET=$routeSecret",
    'PRINT_GATEWAY_HOST=127.0.0.1',
    'PRINT_GATEWAY_PORT=3110',
    "PRINT_GATEWAY_ID=$GatewayId",
    'PRINT_GATEWAY_POLL_MS=1500',
    'PRINT_GATEWAY_CONNECT_TIMEOUT_MS=5000',
    'PRINT_GATEWAY_AUTO_RETRY_LIMIT=2',
    'PRINT_GATEWAY_RESOLVER_ID=d4f3e7fb-8c05-4e26-8d94-5a0b1f3e7d44',
    'POS_COMMAND_RESOLVER_ID=54be0dfa-2fd6-45bc-be93-6ba4c64a21d9',
    'MAHABBAT_BRIDGE_PORT=3111'
  )
  if (-not [string]::IsNullOrWhiteSpace($accessId) -and -not [string]::IsNullOrWhiteSpace($accessSecret)) {
    $configLines += "CLOUDFLARE_ACCESS_CLIENT_ID=$accessId"
    $configLines += "CLOUDFLARE_ACCESS_CLIENT_SECRET=$accessSecret"
  }
  Write-Utf8NoBom (Join-Path $stage 'config\bridge.env') (($configLines -join "`n") + "`n")

  $stations = @(Get-OptionalRemoteRows $envMap 'posProductionStations' | ForEach-Object { [ordered]@{ id = [string]$_.id; label = [string]$_.label; isActive = ($_.isActive -ne $false); printerDeviceId = if ($_.printerDeviceId) { [string]$_.printerDeviceId } else { $null } } })
  $devices = @(Get-OptionalRemoteRows $envMap 'posPrinterDevices' | Where-Object { [string]$_.connectionType -eq 'WINDOWS_SPOOLER' } | ForEach-Object { [ordered]@{ id = [string]$_.id; label = [string]$_.label; systemQueueName = [string]$_.systemQueueName; connectionType = 'WINDOWS_SPOOLER'; paperWidth = [string]$_.paperWidth; encodingProfile = [string]$_.encodingProfile; isPrecheckPrinter = ($_.isPrecheckPrinter -eq $true); isActive = ($_.isActive -ne $false); cutSupport = ($_.cutSupport -ne $false); status = [string]$_.status } })
  $stationsJson = if ($stations.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $stations -Depth 5 }
  $devicesJson = if ($devices.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $devices -Depth 5 }
  Write-Utf8NoBom (Join-Path $stage 'config\stations.json') ($stationsJson + "`n")
  Write-Utf8NoBom (Join-Path $stage 'config\devices.json') ($devicesJson + "`n")

  $manifest = [ordered]@{
    package = 'Mahabbat Temporary Print Bridge'
    version = '1.0.0'
    builtAt = (Get-Date).ToString('o')
    mode = 'REMOTE'
    innerSha = $innerSha
    bundledNode = $nodeVersion
    bundledNodeSha256 = $runtimeSha256
    gateway = 'Existing pos-standalone/server/print-gateway.mjs; no permanent agent.'
    localUi = 'http://127.0.0.1:3111'
    physicalPrinter = 'PENDING RESTAURANT'
    secrets = 'Private config is embedded only in the local private ZIP and is not committed.'
  }
  Write-Utf8NoBom (Join-Path $stage 'PACKAGE-MANIFEST.json') (($manifest | ConvertTo-Json -Depth 5) + "`n")

  if (-not $SkipSelfTest) {
    if (Test-Path -LiteralPath $tempTestPackage) { Remove-Item -LiteralPath $tempTestPackage -Recurse -Force }
    Copy-Item -LiteralPath $stage -Destination $tempTestPackage -Recurse -Force
    $selfTest = Join-Path $sourcePath 'bridge-package-self-test.mjs'
    & $NodePath $selfTest --package-dir $tempTestPackage --inner-dir $innerPath
    if ($LASTEXITCODE -ne 0) { throw 'Portable package self-test failed.' }
  }

  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
  Write-Host "Package created: $zipPath"
  Write-Host 'Private configuration is local-only; secrets were not printed or committed.'
} finally {
  if (Test-Path -LiteralPath $tempTestPackage) { Remove-Item -LiteralPath $tempTestPackage -Recurse -Force -ErrorAction SilentlyContinue }
}
