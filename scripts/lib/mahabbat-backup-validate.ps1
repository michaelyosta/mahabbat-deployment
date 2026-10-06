# Mahabbat backup manifest validation (Stage C, backupVersion 2).
# Additive module: dot-sourced by mahabbat-restore.ps1 / mahabbat-verify-password.ps1
# and (when present) by mahabbat-update.ps1. NEVER edits the legacy
# Get-MahabbatUpdateBackupState in mahabbat-update.ps1 — the updater falls back
# to it on old installs.
#
# backupVersion history:
#   1 = legacy copies (no backupVersion field): DB dump (+optional
#       server-local-data.tar.gz / .empty marker), old manifests may lack
#       keySource and files integrity fields — validator MUST still read them.
#   2 = current: manifest carries backupVersion=2, files/filesSha256 (or the
#       .empty marker + files='server-local-data.empty...'), and for encrypted
#       copies encryption.ciphertextSha256.
#
# Get-MahabbatValidatedBackupState contract (stable, consumed by the updater):
#   param [int]$MaxAgeHours = 24
#   returns PSCustomObject @{ Fresh=[bool]; Path=[string]; AgeHours=[double|$null]; Reason=[string] }
# Fresh=$true ONLY when the newest timestamped dir has a parseable manifest AND
#   all referenced payloads exist with matching integrity AND the timestamp is
#   not in the future AND age <= MaxAgeHours. Every other case fails closed
#   (Fresh=$false + human-readable Reason naming the defect).
# Requires mahabbat-common.ps1 (Get-MahabbatBackupRoot). Integrity hashing uses
#   Get-MahabbatFileSha256Hex when mahabbat-backup-crypto.ps1 is loaded.

$script:MahabbatBackupManifestVersion = 2
$script:MahabbatBackupFutureSkewMinutes = 5

function Test-MahabbatBackupProperty {
  param(
    [Parameter(Mandatory = $true)][psobject]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  try {
    return ($Object.PSObject.Properties.Name -contains $Name)
  } catch {
    return $false
  }
}

function Get-MahabbatBackupManifestVersion {
  param([psobject]$Manifest)
  if ((Test-MahabbatBackupProperty -Object $Manifest -Name 'backupVersion')) {
    try {
      $v = [int]$Manifest.backupVersion
      if ($v -ge 1) { return $v }
    } catch { }
  }
  return 1
}

function Test-MahabbatBackupManifest {
  # Deep validation of ONE backup dir. Returns @{ Ok; Reason; Manifest; BackupVersion }.
  # Read-only: never touches containers, never writes. Version-1 (legacy)
  # manifests without backupVersion/keySource/filesSha256 MUST still validate
  # when their payload files are present.
  param([Parameter(Mandatory = $true)][string]$BackupDir)
  $result = [pscustomobject]@{ Ok = $false; Reason = ''; Manifest = $null; BackupVersion = 0 }
  $manifestPath = Join-Path $BackupDir 'backup-manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $result.Reason = "в $([IO.Path]::GetFileName($BackupDir)) нет backup-manifest.json"
    return $result
  }
  try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $result.Reason = "backup-manifest.json повреждён (не JSON): $([IO.Path]::GetFileName($BackupDir))"
    return $result
  }
  $result.Manifest = $manifest
  $version = Get-MahabbatBackupManifestVersion -Manifest $manifest
  $result.BackupVersion = $version
  if ($version -gt $script:MahabbatBackupManifestVersion) {
    $result.Reason = "копия версии $version новее поддерживаемой ($($script:MahabbatBackupManifestVersion)); обновите скрипты Mahabbat"
    return $result
  }
  if (-not (Test-MahabbatBackupProperty -Object $manifest -Name 'timestamp')) {
    $result.Reason = 'в manifest нет timestamp — комплект неполный'
    return $result
  }
  $stamp = $null
  try { $stamp = [datetime]$manifest.timestamp } catch { $stamp = $null }
  if ($null -eq $stamp) {
    $result.Reason = 'timestamp копии не распознан — комплект неполный'
    return $result
  }
  if ($stamp -gt (Get-Date).AddMinutes($script:MahabbatBackupFutureSkewMinutes)) {
    $result.Reason = 'дата копии в будущем — копия недостоверна'
    return $result
  }
  $isEncrypted = $false
  if ((Test-MahabbatBackupProperty -Object $manifest -Name 'encrypted')) {
    try { $isEncrypted = [bool]$manifest.encrypted } catch { $isEncrypted = $false }
  } elseif ((Test-MahabbatBackupProperty -Object $manifest -Name 'encryption')) {
    $isEncrypted = $true
  }
  if (-not (Test-MahabbatBackupProperty -Object $manifest -Name 'dump')) {
    $result.Reason = 'в manifest нет поля dump — комплект неполный'
    return $result
  }
  $dumpName = [string]$manifest.dump
  if ($isEncrypted -and ($dumpName -ne 'database.dump.enc')) {
    $result.Reason = 'manifest помечен зашифрованным, но dump не database.dump.enc — комплект неполный'
    return $result
  }
  if ((-not $isEncrypted) -and ($dumpName -ne 'database.dump')) {
    $result.Reason = 'manifest обычной копии должен ссылаться на database.dump — комплект неполный'
    return $result
  }
  $dumpPath = Join-Path $BackupDir $dumpName
  if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
    $result.Reason = "файл $dumpName отсутствует — комплект неполный"
    return $result
  }
  try {
    if ((Get-Item -LiteralPath $dumpPath -ErrorAction Stop).Length -le 0) {
      $result.Reason = "файл $dumpName пуст — комплект неполный"
      return $result
    }
  } catch {
    $result.Reason = "файл $dumpName недоступен — комплект неполный"
    return $result
  }
  if ($isEncrypted) {
    # Version-1 manual copies may lack the encryption block or keySource
    # entirely (StrictMode-safe read: property presence first, never direct).
    $hasBlock = (Test-MahabbatBackupProperty -Object $manifest -Name 'encryption')
    $digest = $null
    if ($hasBlock) {
      try {
        if ((Test-MahabbatBackupProperty -Object $manifest.encryption -Name 'ciphertextSha256') -and ($null -ne $manifest.encryption.ciphertextSha256)) {
          $digest = ([string]$manifest.encryption.ciphertextSha256).Trim()
        }
      } catch { $digest = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($digest)) {
      try {
        $actual = (Get-MahabbatFileSha256Hex -Path $dumpPath).ToLowerInvariant()
      } catch {
        $result.Reason = "не удалось проверить целостность $dumpName"
        return $result
      }
      if ($actual -cne $digest.ToLowerInvariant()) {
        $result.Reason = "$dumpName не совпадает с manifest (SHA256) — файл повреждён или подменён"
        return $result
      }
    }
  }
  # Files payload: version-2 records files/filesSha256; version-1 records a
  # free-form files string ('server-local-data.tar.gz' or 'server-local-data.empty ...').
  $filesName = $null
  $filesDigest = $null
  if ((Test-MahabbatBackupProperty -Object $manifest -Name 'filesSha256') -and (-not [string]::IsNullOrWhiteSpace([string]$manifest.filesSha256))) {
    $filesDigest = ([string]$manifest.filesSha256).Trim()
  }
  if ((Test-MahabbatBackupProperty -Object $manifest -Name 'files') -and ($null -ne $manifest.files)) {
    $filesField = [string]$manifest.files
    if ($filesField -match 'server-local-data\.tar\.gz') { $filesName = 'server-local-data.tar.gz' }
  } elseif ($version -ge 2) {
    $result.Reason = 'в manifest v2 нет поля files — комплект неполный'
    return $result
  }
  if ($null -ne $filesName) {
    $filesPath = Join-Path $BackupDir $filesName
    if (-not (Test-Path -LiteralPath $filesPath -PathType Leaf)) {
      $result.Reason = "файл $filesName отсутствует — комплект неполный"
      return $result
    }
    if (-not [string]::IsNullOrWhiteSpace($filesDigest)) {
      try {
        $actualFiles = (Get-MahabbatFileSha256Hex -Path $filesPath).ToLowerInvariant()
      } catch {
        $result.Reason = "не удалось проверить целостность $filesName"
        return $result
      }
      if ($actualFiles -cne $filesDigest.ToLowerInvariant()) {
        $result.Reason = "$filesName не совпадает с manifest (SHA256) — файл повреждён или подменён"
        return $result
      }
    }
  } elseif ($version -ge 2) {
    # v2 without a tar MUST carry the .empty marker (honest "files unavailable").
    if (-not (Test-Path -LiteralPath (Join-Path $BackupDir 'server-local-data.empty') -PathType Leaf)) {
      $result.Reason = 'в копии v2 нет ни server-local-data.tar.gz, ни server-local-data.empty — комплект неполный'
      return $result
    }
  }
  $result.Ok = $true
  $result.Reason = ''
  return $result
}

function Get-MahabbatValidatedBackupState {
  # Updater gate (Stage C contract): Fresh/Path/AgeHours/Reason.
  # Fails closed on: empty/corrupt/incomplete manifest, missing payloads,
  # integrity mismatch, unsupported future version, unparseable timestamp,
  # future-dated copies, stale copies. NEVER throws for fixture content —
  # returns Fresh=$false with a Reason instead (missing backup ROOT counts
  # as "no copy", not as an error).
  param([int]$MaxAgeHours = 24)
  $state = [pscustomobject]@{ Fresh = $false; Path = ''; AgeHours = $null; Reason = '' }
  $root = Get-MahabbatBackupRoot
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    $state.Reason = "каталог копий отсутствует: $root"
    return $state
  }
  $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-\d{6}$' } |
    Sort-Object Name -Descending)
  if ($dirs.Count -eq 0) {
    $state.Reason = "в $root нет копий"
    return $state
  }
  $latest = $dirs[0]
  $check = Test-MahabbatBackupManifest -BackupDir $latest.FullName
  if (-not $check.Ok) {
    $state.Path = $latest.FullName
    $state.Reason = $check.Reason
    return $state
  }
  $manifest = $check.Manifest
  $stamp = $null
  $byDirName = $false
  try { $stamp = [datetime]::ParseExact($latest.Name, 'yyyy-MM-dd-HHmmss', $null) } catch { $stamp = $null }
  if ($null -eq $stamp) {
    try { $stamp = [datetime]$manifest.timestamp } catch { $stamp = $null }
    $byDirName = $false
  } else {
    $byDirName = $true
  }
  if ($null -eq $stamp) {
    $state.Path = $latest.FullName
    $state.Reason = "неизвестный возраст копии $($latest.Name)"
    return $state
  }
  $now = Get-Date
  if ($stamp -gt $now.AddMinutes($script:MahabbatBackupFutureSkewMinutes)) {
    $state.Path = $latest.FullName
    $state.Reason = "дата копии $($latest.Name) в будущем — копия недостоверна"
    return $state
  }
  $ageHours = ($now - $stamp).TotalHours
  if ($ageHours -lt 0) { $ageHours = 0 }
  $state.AgeHours = [math]::Round($ageHours, 1)
  $state.Path = $latest.FullName
  if ($ageHours -le [double]$MaxAgeHours) {
    $state.Fresh = $true
  } else {
    $state.Reason = "копия старше $MaxAgeHours ч (возраст $($state.AgeHours) ч)"
  }
  return $state
}
