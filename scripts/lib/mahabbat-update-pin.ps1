# Mahabbat update pin records (updater-owned, additive).
# Pure check→apply pinning helpers: NO docker, NO compose, NO registry, NO
# runtime changes — safe to dot-source in tests. mahabbat-update.ps1
# dot-sources this lib; the lib only READS the release manifest and locks
# (schema owned by T3 — never written here) and T2's crypto lib when loaded
# (never duplicated here).
# Requires: mahabbat-common.ps1 (Get-MahabbatRoot). Optional:
#   mahabbat-backup-crypto.ps1 (Get-MahabbatFileSha256Hex, else Get-FileHash),
#   Get-MahabbatUpdatePinnedTarget (defined in mahabbat-update.ps1; test
#   harnesses may stub it — resolved at call time).

function Get-MahabbatUpdateFileSha256 {
  # SHA256 of a host file: crypto-lib streamer when loaded, Get-FileHash fallback.
  param([Parameter(Mandatory = $true)][string]$Path)
  if (Get-Command Get-MahabbatFileSha256Hex -ErrorAction SilentlyContinue) {
    return ((Get-MahabbatFileSha256Hex -Path $Path).ToLowerInvariant())
  }
  return (((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToLowerInvariant())
}

function Get-MahabbatUpdateDefaultTargetPath {
  return (Join-Path (Join-Path (Get-MahabbatRoot) '.private') 'update-target.json')
}

function Get-MahabbatMaintenanceFlagPath {
  return (Join-Path (Join-Path (Get-MahabbatRoot) '.private') 'maintenance.json')
}

function Test-MahabbatMaintenanceOpen {
  return (Test-Path -LiteralPath (Get-MahabbatMaintenanceFlagPath) -PathType Leaf)
}

function Get-MahabbatImageRepoWithoutTag {
  # 'ghcr.io/o/r:tag' -> 'ghcr.io/o/r'; 'ghcr.io/o/r@sha256:…' -> 'ghcr.io/o/r'.
  param([Parameter(Mandatory = $true)][string]$Ref)
  $t = ([string]$Ref).Trim()
  $at = $t.IndexOf('@')
  if ($at -gt 0) { return $t.Substring(0, $at) }
  return ($t -replace ':[^/]*$', '')
}

function Get-MahabbatUpdateReleaseFileShas {
  # Integrity identity of the release kit on disk: manifest + both locks.
  $root = Get-MahabbatRoot
  $shas = [ordered]@{}
  foreach ($rel in @('release/mahabbat-release.json', 'image-digests.lock.json', 'mahabbat-inner.lock.json')) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      try { $shas[$rel] = Get-MahabbatUpdateFileSha256 -Path $p } catch { $shas[$rel] = '' }
    } else { $shas[$rel] = '' }
  }
  return $shas
}

function Get-MahabbatReleaseManifest {
  $path = Join-Path (Get-MahabbatRoot) 'release/mahabbat-release.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'release/mahabbat-release.json is missing.' }
  try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
  catch { throw 'release/mahabbat-release.json is invalid JSON.' }
}

function Set-MahabbatUpdateJsonFile {
  # BOM-less UTF8 writer for updater JSON (target record, maintenance flag,
  # journal): node JSON.parse and the wizard API are BOM-intolerant, while
  # PowerShell 5.1 Set-Content -Encoding UTF8 always emits a BOM.
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Json)
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Json, [Text.UTF8Encoding]::new($false))
}

function New-MahabbatUpdateTargetRecord {
  # The check→apply pin (F11, schema 1, updater-owned file): per-image
  # digests for every release artifact + manifest SHA + both locks SHAs.
  # apply installs EXACTLY this record and refuses on any drift.
  param([int]$MaxBackupAgeHours = 24, [psobject]$Pinned = $null)
  if ($null -eq $Pinned) { $pinned = Get-MahabbatUpdatePinnedTarget -MaxBackupAgeHours $MaxBackupAgeHours }
  else { $pinned = $Pinned }
  $release = $pinned.Release
  $shas = Get-MahabbatUpdateReleaseFileShas
  $manifestDigests = [ordered]@{
    branding = [string]$release.images.branding.digest
    venue = [string]$release.images.venue.digest
    posGateway = [string]$release.images.posGateway.digest
  }
  $targets = @($pinned.Rows | ForEach-Object {
    $manifestDigest = ''
    if ($_.Key -eq 'twenty') { $manifestDigest = [string]$release.images.venue.digest }
    elseif ($_.Key -eq 'pos') { $manifestDigest = [string]$release.images.posGateway.digest }
    [pscustomobject]@{
      key = $_.Key
      image = $_.Image
      repo = (Get-MahabbatImageRepoWithoutTag $_.Image)
      targetDigest = $_.TargetDigest
      manifestDigest = $manifestDigest
      remoteDigest = $_.RemoteDigest
    }
  })
  return [ordered]@{
    schema = 1
    mahabbatVersion = [string]$release.mahabbatVersion
    deploymentSha = [string]$release.deploymentSha
    crmSha = [string]$release.crmSha
    manifestSha256 = [string]$shas['release/mahabbat-release.json']
    locksSha256 = [ordered]@{
      'image-digests.lock.json' = [string]$shas['image-digests.lock.json']
      'mahabbat-inner.lock.json' = [string]$shas['mahabbat-inner.lock.json']
    }
    manifestDigests = $manifestDigests
    targets = @($targets)
    checkedAt = ((Get-Date).ToUniversalTime().ToString('o'))
  }
}

function Write-MahabbatUpdateTargetRecord {
  param([string]$Path = '', [int]$MaxBackupAgeHours = 24, [psobject]$Pinned = $null)
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-MahabbatUpdateDefaultTargetPath }
  $doc = New-MahabbatUpdateTargetRecord -MaxBackupAgeHours $MaxBackupAgeHours -Pinned $Pinned
  Set-MahabbatUpdateJsonFile -Path $Path -Json ($doc | ConvertTo-Json -Depth 6)
  return $Path
}

function Test-MahabbatUpdateTargetRecord {
  # Re-asserts the recorded check target against the live release kit.
  # Returns @{ Ok; Reason }. Fails closed on: unknown schema, manifest SHA
  # drift, locks SHA drift, per-image digest drift. Read-only.
  param([Parameter(Mandatory = $true)][psobject]$Recorded)
  if ([string]$Recorded.schema -ne '1') {
    return @{ Ok = $false; Reason = 'Неизвестная схема закреплённой цели — повторите check.' }
  }
  $shas = Get-MahabbatUpdateReleaseFileShas
  if ([string]$Recorded.manifestSha256 -ne [string]$shas['release/mahabbat-release.json']) {
    return @{ Ok = $false; Reason = 'release/mahabbat-release.json изменился после check (SHA не совпадает). Повторите check и подтвердите новый выпуск.' }
  }
  foreach ($name in @('image-digests.lock.json', 'mahabbat-inner.lock.json')) {
    $was = [string]$Recorded.locksSha256.$name
    if ($was -ne [string]$shas[$name]) {
      return @{ Ok = $false; Reason = "$name изменился после check (SHA не совпадает). Повторите check." }
    }
  }
  $release = $null
  try { $release = Get-MahabbatReleaseManifest } catch { $release = $null }
  if ($null -eq $release) {
    return @{ Ok = $false; Reason = 'release/mahabbat-release.json недоступен при apply. Повторите check.' }
  }
  foreach ($t in @($Recorded.targets)) {
    $current = ''
    if ([string]$t.key -eq 'twenty') { $current = [string]$release.images.venue.digest }
    elseif ([string]$t.key -eq 'pos') { $current = [string]$release.images.posGateway.digest }
    else { continue }
    if ([string]::IsNullOrWhiteSpace($current) -or $current -match 'TBD') { continue }
    if ([string]$t.targetDigest -ne $current) {
      return @{ Ok = $false; Reason = "Цель $($t.key) изменилась между check и apply (реестр/выпуск ушёл). Повторите check и подтвердите новый выпуск." }
    }
  }
  return @{ Ok = $true; Reason = '' }
}
