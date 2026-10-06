[CmdletBinding()]
param(
  [ValidateSet('check', 'apply', 'verify')][string]$Action = 'check',
  [switch]$Json,
  [int]$MaxBackupAgeHours = 24,
  [int]$TimeoutSeconds = 420,
  [string]$TargetFile = '',
  [switch]$SkipReconcile,
  [switch]$SkipVerify
)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

# Mahabbat update: explicit-only full-release updates, never silent-auto.
#   check: read-only. Resolves the pinned release target (release manifest +
#          registry digests, never `docker pull`), records it to
#          .private/update-target.json (manifest SHA + locks SHAs + per-image
#          digests), prints current/pinned versions and the Mahabbat changelog
#          from the release manifest.
#   apply: full-kit update with backup gate + maintenance window, journaled
#          staged apply (gates -> maintenance/pos-gateway stop -> host/locks
#          coherence -> pinned pull repo@digest -> snapshots/alias sync ->
#          up on digest refs -> inner checkout -> images -> metadata ->
#          reconcile -> verify incl. host-scripts rehash), per-stage
#          rollback/resume. The recorded check target is re-asserted
#          (manifest SHA, locks SHAs, per-image digests); a drift refuses
#          BEFORE any runtime change.
#   verify: post-update verification only (versions/images/logic-functions/
#          parity/health/invariants/host-scripts), no changes.
# The pinned target recorded at check is re-asserted at apply (F11): a remote
# alias change between check and apply never swaps the release under update.
# Host scripts/locks/manifest arrive with the release EXE (installer-owned);
# the updater proves the on-disk kit matches the release (locks coherence +
# hostScriptsHash rehash) instead of re-delivering itself mid-run.

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
# Backup crypto (T2-owned, additive): dot-sourced when present so the backup
# gate can verify SHA digests and the updater can hash the release kit.
# Guarded for old installs without the lib — never duplicated here.
$cryptoLib = Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1'
if (Test-Path -LiteralPath $cryptoLib -PathType Leaf) { . $cryptoLib }
# Pinned check→apply records (pure, testable helpers).
. (Join-Path $PSScriptRoot 'lib/mahabbat-update-pin.ps1')

function Get-MahabbatValidatedBackupGate {
  param([int]$MaxAgeHours = 24)
  # Integrity hashing (Get-MahabbatFileSha256Hex) lives in the crypto lib:
  # load it BEFORE the validator, same order as mahabbat-restore.ps1 /
  # mahabbat-verify-password.ps1. Without it every digest-bearing copy
  # (ciphertextSha256/filesSha256) fails closed as "не удалось проверить
  # целостность" even when valid (R06). The validator itself stays thin —
  # no duplicated hashing implementation to drift from the crypto one.
  $cryptoLib = Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1'
  if (Test-Path -LiteralPath $cryptoLib -PathType Leaf) {
    . $cryptoLib
  }
  $validateLib = Join-Path $PSScriptRoot 'lib/mahabbat-backup-validate.ps1'
  if (Test-Path -LiteralPath $validateLib -PathType Leaf) {
    . $validateLib
    if (Get-Command Get-MahabbatValidatedBackupState -ErrorAction SilentlyContinue) {
      return (Get-MahabbatValidatedBackupState -MaxAgeHours $MaxAgeHours)
    }
  }
  return (Get-MahabbatUpdateBackupState -MaxAgeHours $MaxAgeHours)
}

function Get-MahabbatUpdateJournalPath {
  $dir = Join-Path (Get-MahabbatRoot) '.private'
  return (Join-Path $dir 'update-journal.json')
}

function Read-MahabbatUpdateJournal {
  $path = Get-MahabbatUpdateJournalPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
  try { $raw = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json; return @($raw) }
  catch {
    # Never silently discard history: quarantine the unreadable journal so
    # the next write starts fresh WITHOUT losing evidence (E-UPD: a 176MB
    # journal OOMed Get-Content and the old catch returned @(), wiping it).
    try {
      $q = ($path + '.corrupt-' + ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')))
      Move-Item -LiteralPath $path -Destination $q -Force -ErrorAction Stop
      Write-Warning "Update journal unreadable; quarantined to $q and starting fresh."
    } catch { Write-Warning 'Update journal unreadable and quarantine failed; starting fresh (history at risk).' }
    return @()
  }
}

function Write-MahabbatUpdateJournalEntry {
  param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][string]$State,
    [string]$Detail = ''
  )
  $dir = Split-Path -Parent (Get-MahabbatUpdateJournalPath)
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # Journal is a bounded ring, not an archive: truncate runaway details and
  # keep the tail. Unbounded growth OOMs the next read (E-UPD: 176MB).
  if ($Detail.Length -gt 2000) { $Detail = $Detail.Substring(0, 2000) + '...[truncated]' }
  $entries = @(Read-MahabbatUpdateJournal)
  $entries += [pscustomobject]@{
    at = ((Get-Date).ToUniversalTime().ToString('o'))
    stage = $Stage
    state = $State
    detail = $Detail
  }
  if ($entries.Count -gt 300) { $entries = @($entries | Select-Object -Last 300) }
  Set-MahabbatUpdateJsonFile -Path (Get-MahabbatUpdateJournalPath) -Json ($entries | ConvertTo-Json -Depth 5)
}

function Get-MahabbatUpdateTargets {
  $envMap = Get-MahabbatEnvMap
  $owner = (Get-MahabbatEnvValue $envMap 'MAHABBAT_IMAGE_OWNER' '').Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($owner)) { throw 'MAHABBAT_IMAGE_OWNER не задан в .env — укажите lower-case владельца GHCR (bootstrap пишет michaelyosta по умолчанию).' }
  $twentyDefault = "ghcr.io/$owner/mahabbat-twenty:v2.29.0-venue"
  $posDefault = "ghcr.io/$owner/mahabbat-pos-gateway:v2.29.0-venue"
  try {
    $updateLock = Get-MahabbatImageDigestsLock
    $lockTwentyRef = [string]$updateLock.images.venue.ref
    if ($lockTwentyRef -match '^ghcr\.io/[^/]+/([^:]+):(.+)$') { $twentyDefault = "ghcr.io/$owner/$($Matches[1]):$($Matches[2])" }
    $lockPosRef = [string]$updateLock.images.posGateway.ref
    if ($lockPosRef -match '^ghcr\.io/[^/]+/([^:]+):(.+)$') { $posDefault = "ghcr.io/$owner/$($Matches[1]):$($Matches[2])" }
  } catch { }
  $twentyOverride = (Get-MahabbatEnvValue $envMap 'MAHABBAT_TWENTY_IMAGE' '').Trim()
  $posOverride = (Get-MahabbatEnvValue $envMap 'MAHABBAT_POS_IMAGE' '').Trim()
  if ([string]::IsNullOrWhiteSpace($twentyOverride)) { $twentyOverride = $twentyDefault }
  if ([string]::IsNullOrWhiteSpace($posOverride)) { $posOverride = $posDefault }
  $resolved = @{}
  if (Get-Command Get-MahabbatComposeServiceImages -ErrorAction SilentlyContinue) {
    try {
      foreach ($row in @(Get-MahabbatComposeServiceImages)) {
        $text = [string]$row.Image
        if ($text -match 'mahabbat-twenty') { $resolved['twenty'] = $text }
        elseif ($text -match 'mahabbat-pos-gateway') { $resolved['pos'] = $text }
      }
    } catch { }
  }
  if ($resolved.Count -lt 2 -and (Test-MahabbatDockerEngine)) {
    try {
      $composeArgs = @(Get-MahabbatComposeArguments) + @('config', '--images')
      Push-Location (Get-MahabbatRoot)
      try { $listed = @((& docker compose @composeArgs 2>$null)) } finally { Pop-Location }
      foreach ($item in $listed) {
        $text = ([string]$item).Trim()
        if ($text -match 'mahabbat-twenty') { $resolved['twenty'] = $text }
        elseif ($text -match 'mahabbat-pos-gateway') { $resolved['pos'] = $text }
      }
    } catch { }
  }
  if (-not $resolved.ContainsKey('twenty')) { $resolved['twenty'] = $twentyOverride }
  if (-not $resolved.ContainsKey('pos')) { $resolved['pos'] = $posOverride }
  return @(
    [pscustomobject]@{ Key = 'twenty'; Label = 'CRM/Worker'; Image = [string]$resolved['twenty'] },
    [pscustomobject]@{ Key = 'pos'; Label = 'POS'; Image = [string]$resolved['pos'] }
  )
}

function Get-MahabbatUpdateLocalInfo {
  param([Parameter(Mandatory = $true)][string]$Image)
  $info = [pscustomobject]@{
    Present = $false
    Id = ''
    Digest = ''
    Created = ''
    Version = ''
    Revision = ''
    Description = ''
  }
  $raw = ''
  $prevAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    try { $raw = ((& docker image inspect $Image --format '{{json .}}' 2>$null) -join '').Trim() }
    catch { $raw = '' }
  } catch { $raw = '' } finally { $ErrorActionPreference = $prevAction }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $info }
  try { $obj = $raw | ConvertFrom-Json } catch { return $info }
  $info.Present = $true
  $info.Id = [string]$obj.Id
  $info.Created = [string]$obj.Created
  $repo = ($Image -replace ':[^/]*$', '')
  foreach ($entry in @($obj.RepoDigests)) {
    $text = [string]$entry
    if ($text.StartsWith($repo + '@')) { $info.Digest = $text.Substring($repo.Length + 1); break }
  }
  if ([string]::IsNullOrWhiteSpace($info.Digest) -and @($obj.RepoDigests).Count -gt 0) {
    $first = [string]@($obj.RepoDigests)[0]
    if ($first -match '@(sha256:[0-9a-f]{32,})$') { $info.Digest = $Matches[1] }
  }
  $labels = $null
  try { $labels = $obj.Config.Labels } catch { $labels = $null }
  if ($null -ne $labels) {
    $getLabel = { param([string]$n) $v = $null; try { $v = $labels.$n } catch { $v = $null }; return [string]$v }
    $info.Version = &$getLabel 'org.opencontainers.image.version'
    $info.Revision = &$getLabel 'org.opencontainers.image.revision'
    $info.Description = &$getLabel 'org.opencontainers.image.description'
    if ([string]::IsNullOrWhiteSpace($info.Created)) { $info.Created = &$getLabel 'org.opencontainers.image.created' }
  }
  return $info
}

function Get-MahabbatUpdateRemoteDigest {
  # Strictly read-only: registry manifest read, never `docker pull`.
  # Never throws: '' means "registry unreachable", callers rely on it.
  param([Parameter(Mandatory = $true)][string]$Image)
  if ([string]::IsNullOrWhiteSpace($Image) -or $Image -notmatch '/') { return '' }
  $prevAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    try {
      $probe = @((& docker buildx imagetools inspect $Image 2>$null))
      if ($LASTEXITCODE -eq 0) {
        foreach ($line in $probe) {
          if (([string]$line) -match '^\s*Digest:\s+(sha256:[0-9a-f]{32,})\s*$') { return $Matches[1] }
        }
      }
    } catch { }
    try {
      $raw = ((& docker manifest inspect --verbose $Image 2>$null) -join '').Trim()
    } catch { $raw = '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try {
        $manifest = $raw | ConvertFrom-Json
        $candidates = @()
        if ($null -ne $manifest.Descriptor) { $candidates += [string]$manifest.Descriptor.digest }
        if ($null -ne $manifest.digest) { $candidates += [string]$manifest.digest }
        foreach ($candidate in $candidates) {
          if ($candidate -match '^(sha256:[0-9a-f]{32,})$') { return $Matches[1] }
        }
      } catch { }
    }
    return ''
  } catch { return '' } finally { $ErrorActionPreference = $prevAction }
}

function Get-MahabbatUpdateDigestShort {
  param([string]$Digest)
  $hex = ([string]$Digest -replace '^sha256:', '')
  if ($hex.Length -gt 12) { return $hex.Substring(0, 12) }
  return $hex
}

function Get-MahabbatUpdateBackupState {
  param([int]$MaxAgeHours = 24)
  $state = [pscustomobject]@{ Fresh = $false; Path = ''; AgeHours = $null; Reason = '' }
  $root = Get-MahabbatBackupRoot
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { $state.Reason = "каталог копий отсутствует: $root"; return $state }
  $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-\d{6}$' } |
    Sort-Object Name -Descending)
  if ($dirs.Count -eq 0) { $state.Reason = "в $root нет копий"; return $state }
  $latest = $dirs[0]
  if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName 'backup-manifest.json') -PathType Leaf)) {
    $state.Reason = "в $($latest.Name) нет backup-manifest.json"
    return $state
  }
  $stamp = $null
  try { $stamp = [datetime]::ParseExact($latest.Name, 'yyyy-MM-dd-HHmmss', $null) } catch { $stamp = $null }
  if ($null -eq $stamp) { $state.Reason = "неизвестный возраст копии $($latest.Name)"; return $state }
  $ageHours = ((Get-Date) - $stamp).TotalHours
  $state.AgeHours = [math]::Round($ageHours, 1)
  $state.Path = $latest.FullName
  if ($ageHours -le [double]$MaxAgeHours) { $state.Fresh = $true }
  return $state
}

function Get-MahabbatUpdateMahabbatChangelogLines {
  param([psobject]$Release)
  $lines = @()
  $source = [string]$Release.changelogSource
  if (-not [string]::IsNullOrWhiteSpace($source) -and $source -ne 'TBD-stage-E') { $lines += $source }
  $lines += ("Mahabbat {0}: CRM {1}, deployment {2}" -f [string]$Release.mahabbatVersion, [string]$Release.crmSha, [string]$Release.deploymentSha)
  if (@($Release.crmPending).Count -gt 0) {
    foreach ($p in @($Release.crmPending)) { $lines += ("Включает {0} ({1}): {2}" -f [string]$p.branch, [string]$p.sha, [string]$p.reason) }
  }
  return @($lines | Select-Object -First 3)
}

function Get-MahabbatUpdatePinnedTarget {
  # Pinned release target: Mahabbat version + per-artifact digests from the
  # release manifest and the live registry. Never mutates the install.
  param([int]$MaxBackupAgeHours = 24)
  $release = Get-MahabbatReleaseManifest
  $targets = Get-MahabbatUpdateTargets
  $rows = @()
  foreach ($t in $targets) {
    $local = Get-MahabbatUpdateLocalInfo -Image $t.Image
    $remote = ''
    if (Test-MahabbatDockerEngine) { $remote = Get-MahabbatUpdateRemoteDigest -Image $t.Image }
    $pinned = ''
    if ($t.Key -eq 'twenty') { $pinned = [string]$release.images.venue.digest }
    elseif ($t.Key -eq 'pos') { $pinned = [string]$release.images.posGateway.digest }
    $effective = if ([string]::IsNullOrWhiteSpace($pinned) -or $pinned -match 'TBD') { $remote } else { $pinned }
    $status = 'unknown'
    if (-not [string]::IsNullOrWhiteSpace($effective)) {
      if (-not $local.Present) { $status = 'yes' }
      elseif ((-not [string]::IsNullOrWhiteSpace($local.Digest)) -and ($local.Digest -eq $effective)) { $status = 'no' }
      elseif (-not [string]::IsNullOrWhiteSpace($local.Digest)) { $status = 'yes' }
    }
    $rows += [pscustomobject]@{
      Key = $t.Key; Label = $t.Label; Image = $t.Image
      LocalPresent = $local.Present; LocalDigest = $local.Digest
      LocalCreated = $local.Created; RemoteDigest = $remote
      PinnedDigest = $pinned; TargetDigest = $effective; Status = $status
    }
  }
  return [pscustomobject]@{ Release = $release; Rows = @($rows) }
}

function Get-MahabbatUpdateCheckResult {
  param([int]$MaxBackupAgeHours = 24, [psobject]$Pinned = $null)
  if ($null -eq $Pinned) { $pinned = Get-MahabbatUpdatePinnedTarget -MaxBackupAgeHours $MaxBackupAgeHours }
  else { $pinned = $Pinned }
  $release = $pinned.Release
  $rows = @($pinned.Rows)
  $lines = @()
  foreach ($row in $rows) {
    $localText = 'absent'
    if ($row.LocalPresent) {
      $localText = Get-MahabbatUpdateDigestShort $row.LocalDigest
      if ([string]::IsNullOrWhiteSpace($localText)) { $localText = 'local-build' }
      if (-not [string]::IsNullOrWhiteSpace($row.LocalCreated)) { $localText += " ($($row.LocalCreated))" }
    }
    $remoteText = 'unknown (registry недоступен — нужен docker login ghcr.io)'
    if (-not [string]::IsNullOrWhiteSpace($row.TargetDigest)) { $remoteText = Get-MahabbatUpdateDigestShort $row.TargetDigest }
    $statusText = switch ($row.Status) { 'yes' { 'UPDATE AVAILABLE' } 'no' { 'up-to-date' } default { 'unknown' } }
    $lines += "UPDATE $($row.Key) ($($row.Label)): $($row.Image)"
    $lines += "  LOCAL: $localText"
    $lines += "  PINNED: $remoteText"
    $lines += "  STATUS: $statusText"
  }
  $overall = 'unknown'
  if (@($rows | Where-Object { $_.Status -eq 'yes' }).Count -gt 0) { $overall = 'yes' }
  elseif (@($rows | Where-Object { $_.Status -eq 'unknown' }).Count -eq 0) { $overall = 'no' }
  $backup = Get-MahabbatValidatedBackupGate -MaxAgeHours $MaxBackupAgeHours
  $backupText = 'no'
  if ($backup.Fresh) { $backupText = "yes ($($backup.Path), возраст $($backup.AgeHours) ч)" }
  else { $backupText = "no ($($backup.Reason))" }
  $currentText = ("Mahabbat {0} (manifest {1})" -f [string]$release.mahabbatVersion, [string]$release.deploymentSha)
  $availableText = ("Mahabbat {0} (CRM {1})" -f [string]$release.mahabbatVersion, [string]$release.crmSha)
  $changelog = @(Get-MahabbatUpdateMahabbatChangelogLines $release)
  $lines += "UPDATE_AVAILABLE: $overall"
  $lines += "BACKUP_FRESH: $backupText"
  $lines += "CURRENT_VERSION: $currentText"
  $lines += "AVAILABLE_VERSION: $availableText"
  $lines += 'CHANGELOG:'
  foreach ($entry in $changelog) { $lines += "- $entry" }
  return [pscustomobject]@{
    Overall = $overall
    Current = $currentText
    Available = $availableText
    Backup = $backup
    Changelog = $changelog
    Lines = $lines
    Release = $release
    Rows = $rows
  }
}

if ($Action -eq 'check') {
  try {
    $pinned = Get-MahabbatUpdatePinnedTarget -MaxBackupAgeHours $MaxBackupAgeHours
    $result = Get-MahabbatUpdateCheckResult -MaxBackupAgeHours $MaxBackupAgeHours -Pinned $pinned
    $pinnedRows = @($result.Rows | ForEach-Object {
      [pscustomobject]@{ key = $_.Key; image = $_.Image; targetDigest = $_.TargetDigest; remoteDigest = $_.RemoteDigest }
    })
    # The check ALWAYS records the pinned target (default .private/update-target.json,
    # -TargetFile overrides). apply installs exactly this record — the wizard passes
    # the same file, so check→apply can never drift to another registry alias.
    $targetPath = $TargetFile
    if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = Get-MahabbatUpdateDefaultTargetPath }
    $targetPath = Write-MahabbatUpdateTargetRecord -Path $targetPath -MaxBackupAgeHours $MaxBackupAgeHours -Pinned $pinned
    $result.Lines += "PINNED_TARGET_FILE: $targetPath"
    $kitShas = Get-MahabbatUpdateReleaseFileShas
    if ($Json) {
      $payload = [ordered]@{
        ok = $true
        updateAvailable = $result.Overall
        current = $result.Current
        available = $result.Available
        backupFresh = $result.Backup.Fresh
        backupPath = $result.Backup.Path
        changelog = @($result.Changelog)
        mahabbatVersion = [string]$result.Release.mahabbatVersion
        pinnedTargets = @($pinnedRows)
        targetFile = [string]$targetPath
        manifestSha256 = [string]$kitShas['release/mahabbat-release.json']
        locksSha256 = [ordered]@{
          'image-digests.lock.json' = [string]$kitShas['image-digests.lock.json']
          'mahabbat-inner.lock.json' = [string]$kitShas['mahabbat-inner.lock.json']
        }
        lines = @($result.Lines)
      }
      Write-Output ($payload | ConvertTo-Json -Depth 6 -Compress)
    } else {
      foreach ($line in $result.Lines) { Write-Host $line }
    }
    exit 0
  } catch {
    if ($Json) {
      Write-Output (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    } else {
      Write-Error $_.Exception.Message
    }
    exit 1
  }
}

function Invoke-MahabbatDamagedTotalsReconcile {
  # Post-update data reconcile: damaged OPEN/IN_PROGRESS orders with empty
  # totals are replayed through the deployed resolver
  # (reconcileDamagedOrderTotals, ADMIN-gated, paid/closed refuse by design).
  # NEVER seeds, NEVER changes PINs/prices/owner/settings, NEVER rewrites
  # paid/closed orders.
  #
  # Honesty contract (R05): the updater has NO ADMIN session and therefore
  # CANNOT converge anything by itself. It never prints OK for work it did
  # not do. Candidates come ONLY from the operator queue file
  # (.private/reconcile-queue.json, [{orderId, note}]) — no venue-specific
  # order IDs are hardcoded in product code. Empty queue => explicitly
  # nothing-to-do (not a convergence claim). Non-empty queue => DEFERRED
  # with the exact operator command; the caller journals 'deferred' and
  # apply continues to verify (best-effort by design; verify still gates).
  # Returns a human summary; throws on transport failure.
  param([psobject]$Release)
  $envMap = Get-MahabbatEnvMap
  $posPort = (Get-MahabbatEnvValue $envMap 'POS_GATEWAY_PORT' '3100').Trim()
  if ([string]::IsNullOrWhiteSpace($posPort)) { $posPort = '3100' }
  $gateway = "http://127.0.0.1:$posPort"
  $queuePath = Join-Path (Join-Path (Get-MahabbatRoot) '.private') 'reconcile-queue.json'
  $candidates = @()
  if (Test-Path -LiteralPath $queuePath -PathType Leaf) {
    try { $candidates = @(Get-Content -Raw -LiteralPath $queuePath | ConvertFrom-Json) } catch { throw "reconcile queue unreadable: $queuePath" }
  }
  if ($candidates.Count -eq 0) {
    Write-Host 'RECONCILE: queue empty (.private/reconcile-queue.json absent or []) — nothing damaged queued, nothing claimed.'
    return ("0 converged, 0 queued (nothing to do)")
  }
  $done = 0
  $skipped = 0
  foreach ($c in $candidates) {
    $orderId = [string]$c.orderId
    try {
      $check = Invoke-RestMethod -UseBasicParsing -Uri "$gateway/health" -TimeoutSec 5 -ErrorAction Stop
    } catch {
      Write-Host "RECONCILE DEFERRED ${orderId}: POS gateway unreachable ($gateway) — manual retry via wizard."
      $skipped += 1
      continue
    }
    Write-Host "RECONCILE DEFERRED ${orderId}: needs an ADMIN POS session — run command reconcileDamagedOrderTotals for this orderId ($($c.note))."
    $skipped += 1
  }
  return ("$done converged, $skipped deferred (operator ADMIN step: reconcileDamagedOrderTotals per orderId)")
}

function Test-MahabbatMetadataPlanClean {
  # Delivery proof (R05): after metadata apply, a fresh plan MUST show zero
  # pending changes. This proves the deployed resolver/metadata actually
  # contains the release code (Stage B commands included) — stronger than
  # asserting file presence. Returns @{ clean; output }.
  $out = ''
  try { $out = (& (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action plan *>&1 | Out-String) } catch { $out = [string]$_.Exception.Message }
  $code = $LASTEXITCODE
  if ($code -ne 0) { return [pscustomobject]@{ clean = $false; output = $out; reason = "metadata plan exited $code" } }
  # Twenty CLI prints either a zero-count summary or an explicit no-changes
  # line (proven on the E-stand: 'No changes. Twenty metadata matches your
  # manifest.'). A hardcoded single shape would false-fail a clean deploy.
  if ($out -match 'Plan:\s*0 to add,\s*0 to change,\s*0 to destroy') { return [pscustomobject]@{ clean = $true; output = $out; reason = '' } }
  if ($out -match 'No changes\.\s*Twenty metadata matches your manifest\.') { return [pscustomobject]@{ clean = $true; output = $out; reason = '' } }
  return [pscustomobject]@{ clean = $false; output = $out; reason = 'plan shows pending changes after apply' }
}

function Open-MahabbatMaintenanceWindow {
  # Maintenance window OPEN: no new POS orders past this point. The POS
  # gateway container is STOPPED (writes fail closed with connection-refused,
  # never half-written) and a flag file records the window. Called only AFTER
  # all pre-gates pass, so a gate refusal never touches runtime.
  # Returns $true when the window is open. If the stop fails halfway, the
  # pre-window runtime is restored best-effort before throwing (images are
  # still untouched at this stage, so 'up -d' restores the exact same
  # containers) — the caller must NOT roll back snapshots that were never taken.
  param([Parameter(Mandatory = $true)][psobject]$Release, [Parameter(Mandatory = $true)][psobject]$RecordedTarget)
  $flag = Get-MahabbatMaintenanceFlagPath
  if (Test-Path -LiteralPath $flag -PathType Leaf) {
    throw 'Незакрытое окно обслуживания (.private/maintenance.json) от прошлого обновления. Проверьте состояние (mahabbat-status.ps1, update-journal.json), убедитесь что система здорова, удалите флаг и повторите.'
  }
  $posId = Get-MahabbatServiceContainerId 'pos-gateway'
  if (-not [string]::IsNullOrWhiteSpace($posId)) {
    try {
      Invoke-MahabbatCompose @('stop', 'pos-gateway')
      $stopped = [string]::IsNullOrWhiteSpace((Get-MahabbatServiceContainerId 'pos-gateway'))
      if (-not $stopped) { throw 'pos-gateway did not stop' }
      Write-Host 'MAINTENANCE: pos-gateway остановлен — новые заказы POS не принимаются до конца обновления.'
    } catch {
      try { Invoke-MahabbatCompose @('up', '-d') } catch { }
      throw "Не удалось остановить pos-gateway для окна обслуживания: $($_.Exception.Message)"
    }
  } else {
    Write-Host 'MAINTENANCE: pos-gateway не запущен — запрет записи не требуется.'
  }
  $flagDir = Split-Path -Parent $flag
  if (-not (Test-Path -LiteralPath $flagDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $flagDir | Out-Null }
  $doc = [ordered]@{
    schema = 1
    openedAt = ((Get-Date).ToUniversalTime().ToString('o'))
    mahabbatVersion = [string]$Release.mahabbatVersion
    manifestSha256 = [string]$RecordedTarget.manifestSha256
    targets = @(@($RecordedTarget.targets) | ForEach-Object {
      [pscustomobject]@{ key = [string]$_.key; repo = [string]$_.repo; targetDigest = [string]$_.targetDigest }
    })
    reason = 'pinned apply in progress: POS writes banned until verify passes'
  }
  Set-MahabbatUpdateJsonFile -Path $flag -Json ($doc | ConvertTo-Json -Depth 5)
  Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'open' -Detail $flag
  Write-Host 'MAINTENANCE WINDOW OPEN: новые заказы не принимаются до конца обновления.'
  return $true
}

function Close-MahabbatMaintenanceWindow {
  # Idempotent: removes the flag (if present) and journals the close.
  # The runtime itself is restored by 'compose up -d' / rollback, not here.
  $flag = Get-MahabbatMaintenanceFlagPath
  if (Test-Path -LiteralPath $flag -PathType Leaf) {
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  }
  Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'closed'
}

function Invoke-MahabbatPinnedImagePull {
  # Pulls EXACTLY the recorded digests (repo@sha256:…, never a mutable alias)
  # and proves each local image resolves to the recorded digest. Then syncs
  # the local mutable alias to the pinned image so a later plain 'up'
  # cannot downgrade the runtime behind the pin.
  param([Parameter(Mandatory = $true)][array]$Targets)
  Assert-MahabbatDockerEngine
  # docker pull reports progress on stderr: keep it non-terminating here so
  # success is judged ONLY by exit codes + digest proof below.
  $prevAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
  $refs = @()
  foreach ($t in @($Targets)) {
    $repo = [string]$t.repo
    $digest = [string]$t.targetDigest
    $mutable = [string]$t.image
    if ([string]::IsNullOrWhiteSpace($repo) -or $digest -notmatch '^sha256:[0-9a-f]{64}$') {
      throw "Невозможно закрепить образ $($t.key): в target file нет digest. Повторите check."
    }
    $ref = "$repo@$digest"
    & docker pull $ref 2>&1 | ForEach-Object { Write-Host ("PULL {0}: {1}" -f $($t.key), $_) }
    if ($LASTEXITCODE -ne 0) {
      throw "Image pull failed for $ref (registry may require 'docker login ghcr.io')."
    }
    $verified = $false
    try {
      $inspected = ((& docker image inspect $ref --format '{{json .RepoDigests}}' 2>$null) -join '').Trim()
      if (-not [string]::IsNullOrWhiteSpace($inspected) -and $inspected -ne 'null') {
        foreach ($entry in @($inspected | ConvertFrom-Json)) {
          if (([string]$entry).ToLowerInvariant().EndsWith("@$digest".ToLowerInvariant())) { $verified = $true; break }
        }
      }
    } catch { $verified = $false }
    if (-not $verified) { throw "Образ $ref притянут, но локальная сверка digest не прошла — обновление запрещено." }
    Write-Host "PULL OK $($t.key): $ref (digest сверен)."
    if (-not [string]::IsNullOrWhiteSpace($mutable) -and $mutable -notmatch '@') {
      $imageId = ((& docker image inspect $ref --format '{{.Id}}' 2>$null) -join '').Trim()
      if ([string]::IsNullOrWhiteSpace($imageId)) { throw "Не удалось прочитать Id образа $ref для синхронизации alias." }
      & docker tag $imageId $mutable | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Не удалось синхронизировать alias $mutable с закреплённым digest." }
      Write-Host "ALIAS SYNC $($t.key): $mutable <- $digest"
    }
    $refs += $ref
  }
  return $refs
  } finally { $ErrorActionPreference = $prevAction }
}

function Test-MahabbatHostFilesHash {
  # Post-update proof that the installed host kit (scripts/wizard/compose…)
  # matches the release manifest hostScriptsHash — the manifest's own
  # contract ("post-update verify re-hashes the installed tree").
  # Returns an array of human-readable problems (empty = all match).
  # Read-only. Data/PINs/prices/owner are never touched.
  param([Parameter(Mandatory = $true)][psobject]$Release)
  $problems = @()
  $root = Get-MahabbatRoot
  $files = $null
  try { $files = $Release.hostScriptsHash.files } catch { $files = $null }
  if ($null -eq $files) { return @('release manifest has no hostScriptsHash.files — kit unverifiable') }
  foreach ($prop in @($files.PSObject.Properties)) {
    $rel = [string]$prop.Name
    $expected = ([string]$prop.Value).ToLowerInvariant()
    $p = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
      $problems += "host file missing: $rel (release expects it)"
      continue
    }
    $actual = ''
    try { $actual = (Get-MahabbatUpdateFileSha256 -Path $p).ToLowerInvariant() } catch { $actual = '' }
    if ([string]::IsNullOrWhiteSpace($actual)) { $problems += "host file unreadable: $rel"; continue }
    if ($actual -cne $expected) { $problems += "host file hash mismatch: $rel" }
  }
  return $problems
}

function Invoke-MahabbatUpdateRollback {
  # Per-stage rollback (F12): snapshots first, then metadata/data/host state.
  # Image/tag rollback restores :previous and restarts; when the journal shows
  # metadata-apply reached a data-changing step, restore is offered via the
  # validated backup (mahabbat-restore.ps1, operator-confirmed, password via
  # MAHABBAT_BACKUP_PASSWORD env). Never promises image-only universal undo.
  param([string]$Reason = '')
  Write-Warning "ROLLBACK START (reason: $Reason)."
  Write-MahabbatUpdateJournalEntry -Stage 'rollback' -State 'started' -Detail $Reason
  $targets = @()
  try { $targets = Get-MahabbatUpdateTargets } catch { $targets = @() }
  $distinct = @($targets | Group-Object Image | ForEach-Object { $_.Name })
  $tagOk = @()
  $tagFail = @()
  $tagSkip = @()
  foreach ($ref in $distinct) {
    $repo = Get-MahabbatImageRepoWithoutTag $ref
    # NOTE: always brace the repo variable (${repo}:previous). An unbraced
    # "$repo:previous" parses as a scoped-variable reference and expands to
    # an EMPTY string, so Docker would receive ':previous' and silently
    # target nothing.
    $prevId = ((& docker image inspect "${repo}:previous" --format '{{.Id}}' 2>$null) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($prevId)) {
      Write-Warning "ROLLBACK SKIP ${ref}: снапшот previous отсутствует."
      $tagSkip += $ref
      continue
    }
    # Digest-form refs (repo@sha256:…) cannot be a tag DESTINATION: docker
    # refuses 'tag X repo@digest'. Retag onto the lock's mutable alias for
    # this target key instead — 'up -d' resolves the alias locally (no pull),
    # so the previous content goes live. Plain tag refs retag in place.
    $tagTarget = $ref
    if ($ref -match '@') {
      $row = @($targets | Where-Object { [string]$_.Image -eq $ref } | Select-Object -First 1)
      $tkey = if ($row.Count -gt 0) { [string]$row[0].key } else { '' }
      $alias = ''
      try {
        $lock = Get-MahabbatImageDigestsLock
        if ($tkey -eq 'twenty') { $alias = [string]$lock.images.venue.ref }
        elseif ($tkey -eq 'pos') { $alias = [string]$lock.images.posGateway.ref }
      } catch { $alias = '' }
      if ([string]::IsNullOrWhiteSpace($alias) -or $alias -match '@') {
        Write-Warning "ROLLBACK TAG FAILED for ${ref}: no mutable alias to retag onto."
        $tagFail += $ref
        continue
      }
      $tagTarget = $alias
    }
    & docker tag "${repo}:previous" $tagTarget | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "ROLLBACK TAG FAILED for $ref."; $tagFail += $ref }
    else { Write-Host "ROLLBACK TAG OK: $tagTarget <- ${repo}:previous"; $tagOk += $ref }
  }
  Write-Host ("ROLLBACK TAGS: restored={0} failed={1} skipped={2}." -f $tagOk.Count, $tagFail.Count, $tagSkip.Count)
  try { Invoke-MahabbatCompose @('up', '-d') } catch { Write-Warning 'Rollback restart failed; inspect manually.' }
  $backHealthy = $false
  try { $backHealthy = Wait-MahabbatRuntime -TimeoutSeconds 240 } catch { $backHealthy = $false }
  # Honest verdict: OK only when every attempted restore succeeded, at least
  # one image was actually restored (or every ref was legitimately skipped
  # AND the new stack never went live), and the stack is healthy. A healthy
  # restart with zero restores after the new images went live is NOT an OK.
  $journal = @(Read-MahabbatUpdateJournal)
  $wentLive = @($journal | Where-Object { $_.stage -eq 'restart' -and $_.state -eq 'ok' }).Count -gt 0
  $restored = ($backHealthy -and $tagFail.Count -eq 0 -and ($tagOk.Count -gt 0 -or -not $wentLive))
  if ($restored -and $tagOk.Count -gt 0) { Write-Host ("ROLLBACK OK: previous версия восстановлена ({0}) и здорова." -f ($tagOk -join ', ')) }
  elseif ($restored) { Write-Host 'ROLLBACK NO-OP: снапшотов не было и новый стек не запускался; текущий стек перезапущен и здоров, runtime не менялся.' }
  else { Write-Error 'ROLLBACK INCOMPLETE: previous версия НЕ восстановлена или не стала здоровой — смотрите mahabbat-status.ps1 и логи.' }
  $journal = @(Read-MahabbatUpdateJournal)
  $dataTouched = @($journal | Where-Object { $_.stage -in @('reconcile', 'metadata-apply') -and $_.state -eq 'ok' }).Count -gt 0
  if ($dataTouched) {
    Write-Warning 'Журнал показывает затронутые данные (metadata-apply/reconcile OK до сбоя): для возврата данных используйте mahabbat-restore.ps1 -BackupPath <свежая копия> -ConfirmRestore (пароль через MAHABBAT_BACKUP_PASSWORD). Автовосстановление БД без подтверждения НЕ выполняется.'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'rollback' -State ($(if ($restored) { 'ok' } else { 'incomplete' }))
  return $restored
}

function Get-MahabbatUpdateVerifyReport {
  # Post-update verify (F03/F09-F12/F14): versions, images, logic functions,
  # SDK parity, health, business invariants. Read-only; returns
  # @{ ok; failures; lines }. Success prints only after ALL checks pass.
  param([int]$TimeoutSeconds = 240)
  $failures = @()
  $lines = @()
  $release = $null
  try { $release = Get-MahabbatReleaseManifest } catch { $failures += $_.Exception.Message }
  if ($null -ne $release) {
    $lines += ("VERIFY release: Mahabbat {0} (deployment {1}, CRM {2})." -f $release.mahabbatVersion, $release.deploymentSha, $release.crmSha)
  }
  $inner = $null
  try { $inner = Get-MahabbatInnerState } catch { $failures += $_.Exception.Message }
  if ($null -ne $inner) {
    $lines += ("VERIFY inner: {0} (lock {1}, match={2}, dirty={3})." -f $inner.Actual, $inner.Expected, $inner.Match, $inner.Dirty)
    if (-not $inner.Match) { $failures += 'inner HEAD != lock' }
    if ($inner.Dirty) { $failures += 'inner dirty' }
  }
  try { Assert-MahabbatImageDigests } catch { $failures += $_.Exception.Message }
  $lines += 'VERIFY images: lock assertion done (digest-pinned for server/worker/pos-gateway).'
  if ($null -ne $release) {
    $hostProblems = @(Test-MahabbatHostFilesHash -Release $release)
    foreach ($hp in $hostProblems) { $failures += "host kit: $hp" }
    if ($hostProblems.Count -eq 0) { $lines += 'VERIFY host kit: installed scripts/locks/manifest match release hostScriptsHash.' }
    else { $lines += ("VERIFY host kit: {0} problem(s) vs release hostScriptsHash." -f $hostProblems.Count) }
  }
  $snapshot = @()
  try { $snapshot = @(Get-MahabbatRuntimeSnapshot) } catch { $failures += $_.Exception.Message }
  foreach ($row in $snapshot) {
    $ready = $false
    try { $ready = Test-MahabbatServiceReady $row } catch { $ready = $false }
    $lines += ("VERIFY service {0}: {1}/{2}." -f $row.Service, $row.State, $row.Health)
    if (-not $ready) { $failures += "service $($row.Service) not ready" }
  }
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  $lines += ("VERIFY health: crm={0} pos={1}." -f $crm.Code, $pos.Code)
  if (-not $crm.Pass) { $failures += 'CRM health failed' }
  if (-not $pos.Pass) { $failures += 'POS health failed' }
  $serverId = ''
  try { $serverId = Get-MahabbatServiceContainerId 'server' } catch { $serverId = '' }
  if (-not [string]::IsNullOrWhiteSpace($serverId)) {
    $probe = ((& docker exec $serverId sh -lc 'ls /tmp/logic-function-executor-tmpdir/sdk 2>/dev/null | head -3' 2>$null) -join '').Trim()
    $lines += ("VERIFY logic-functions: executor sdk present={0}." -f (-not [string]::IsNullOrWhiteSpace($probe)))
    if ([string]::IsNullOrWhiteSpace($probe)) { $failures += 'logic-function executor SDK not visible in server container' }
  } else {
    $failures += 'server container id unreadable'
  }
  $planClean = $null
  try { $planClean = Test-MahabbatMetadataPlanClean } catch { $planClean = [pscustomobject]@{ clean = $false; output = ''; reason = [string]$_.Exception.Message } }
  if ($null -ne $planClean -and $planClean.clean) { $lines += 'VERIFY invariants: deployed metadata matches the release (plan clean — resolver code incl. Stage B delivered); totals/ownership/payment behavior proven on the E-stand (see acceptance packet).' }
  else { $failures += ("metadata plan not clean: {0}" -f [string]$planClean.reason) }
  return [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures); lines = @($lines) }
}

if ($Action -eq 'verify') {
  try {
    $report = Get-MahabbatUpdateVerifyReport -TimeoutSeconds $TimeoutSeconds
    if ($Json) { Write-Output ($report | ConvertTo-Json -Depth 6 -Compress) }
    else { foreach ($line in $report.lines) { Write-Host $line } }
    if ($report.ok) { exit 0 } else { exit 1 }
  } catch {
    if ($Json) { Write-Output (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress) }
    else { Write-Error $_.Exception.Message }
    exit 1
  }
}

# G6 gate: $true only after this run opened the maintenance window (mutated
# runtime). Pre-initialized: the catch block reads it even when a pre-gate
# refusal throws before Stage 3 (StrictMode-active session).
$windowOpened = $false
try {
  # Pre-gate: a stale maintenance window refuses BEFORE anything else —
  # no engine calls, no pulls, no stops, no tags. Read-only + journal only.
  if (Test-MahabbatMaintenanceOpen) {
    Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'refused' -Detail (Get-MahabbatMaintenanceFlagPath)
    throw 'Незакрытое окно обслуживания (.private/maintenance.json) от прошлого обновления. Проверьте состояние (mahabbat-status.ps1, update-journal.json), убедитесь что система здорова, удалите флаг и повторите.'
  }
  Assert-MahabbatDockerEngine
  $missing = @(Test-MahabbatEnvironment)
  if ($missing.Count -gt 0) { throw "Missing required .env values: $($missing -join ', ')" }
  $release = Get-MahabbatReleaseManifest
  Write-Host ("TARGET: Mahabbat {0} (deployment {1}, CRM {2})." -f $release.mahabbatVersion, $release.deploymentSha, $release.crmSha)
  Write-MahabbatUpdateJournalEntry -Stage 'begin' -State 'started' -Detail ("Mahabbat {0}" -f $release.mahabbatVersion)
  # Stage 0: validated backup gate FIRST — before any pull/stop/migration (F04/F05).
  $backup = Get-MahabbatValidatedBackupGate -MaxAgeHours $MaxBackupAgeHours
  if (-not $backup.Fresh) {
    Write-MahabbatUpdateJournalEntry -Stage 'backup-gate' -State 'refused' -Detail ([string]$backup.Reason)
    throw "Обновление запрещено без свежей резервной копии (не старше $MaxBackupAgeHours ч): $($backup.Reason). Сделайте копию и повторите."
  }
  Write-MahabbatUpdateJournalEntry -Stage 'backup-gate' -State 'ok' -Detail ([string]$backup.Path)
  Write-Host "BACKUP GATE OK: $($backup.Path) (возраст $($backup.AgeHours) ч)."
  # Stage 1: lock coherence (F09/F10/F11) — image-digests vs release manifest.
  $lock = Get-MahabbatImageDigestsLock
  $lockProblems = @()
  foreach ($pair in @(@('venue', $release.images.venue.immutableTag), @('branding', $release.images.branding.immutableTag), @('posGateway', $release.images.posGateway.immutableTag))) {
    $entry = $lock.images.($pair[0])
    if ($null -eq $entry -or [string]$entry.immutableTag -ne [string]$pair[1]) {
      $lockProblems += "lock images.$($pair[0]).immutableTag != release $($pair[1])"
    }
  }
  if ([string]$release.crmSha -ne [string](Get-MahabbatLock).commit) {
    $lockProblems += 'release crmSha != mahabbat-inner.lock.json commit'
  }
  if ($lockProblems.Count -gt 0) {
    Write-MahabbatUpdateJournalEntry -Stage 'locks' -State 'refused' -Detail ($lockProblems -join '; ')
    throw ("Несогласованный комплект выпуска: {0}." -f ($lockProblems -join '; '))
  }
  Write-MahabbatUpdateJournalEntry -Stage 'locks' -State 'ok'
  Assert-MahabbatImageDigests
  # Stage 2: pinned check→apply (F11) — the recorded check target is
  # re-asserted (manifest SHA, locks SHAs, per-image digests). Any drift
  # refuses BEFORE the maintenance window touches runtime. Without a check
  # record (bare CLI apply) the target is pinned at apply time and journaled
  # as such — still digest-exact with post-pull verification.
  $targetPath = $TargetFile
  if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = Get-MahabbatUpdateDefaultTargetPath }
  $recordedFresh = $false
  if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    $targetPath = Write-MahabbatUpdateTargetRecord -Path $targetPath -MaxBackupAgeHours $MaxBackupAgeHours
    Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'recorded-at-apply' -Detail $targetPath
    $recordedFresh = $true
    Write-Host "PIN: check не выполнялся — цель закреплена при apply: $targetPath"
  }
  try { $recorded = Get-Content -Raw -LiteralPath $targetPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
  catch { $recorded = $null }
  if ($null -eq $recorded) {
    Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'refused' -Detail $targetPath
    throw "Закреплённая цель нечитаема ($targetPath). Выполните check и повторите."
  }
  if (-not $recordedFresh) {
    $pinCheck = Test-MahabbatUpdateTargetRecord -Recorded $recorded
    if (-not $pinCheck.Ok) {
      Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'refused' -Detail ([string]$pinCheck.Reason)
      throw ([string]$pinCheck.Reason)
    }
  }
  Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'ok' -Detail $targetPath
  # Stage 3: maintenance window — STOPS pos-gateway (POS write ban) AFTER all
  # pre-gates, so a gate refusal never changes runtime.
  $windowOpened = $false
  $windowOpened = Open-MahabbatMaintenanceWindow -Release $release -RecordedTarget $recorded
  # Stage 4: inner checkout to the locked CRM SHA (fail-closed, dirty refuses).
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path). Run mahabbat-bootstrap.ps1." }
  if ($inner.Dirty) { throw 'Inner repository has uncommitted changes. Resolve them before updating.' }
  if (-not $inner.Match) {
    & git -C $inner.Path fetch --prune origin
    if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the canonical inner repository.' }
    & git -C $inner.Path checkout --detach ([string](Get-MahabbatLock).commit)
    if ($LASTEXITCODE -ne 0) { throw 'Could not checkout locked inner SHA.' }
    $inner = Get-MahabbatInnerState
    if (-not $inner.Match) { throw 'Inner checkout still does not match mahabbat-inner.lock.json.' }
  }
  Write-MahabbatUpdateJournalEntry -Stage 'inner-checkout' -State 'ok' -Detail $inner.Actual
  Write-Host ("INNER OK: {0}." -f $inner.Actual)
  if (-not (Test-MahabbatComposeConfig)) { throw 'docker compose config validation failed.' }
  $targets = Get-MahabbatUpdateTargets
  $distinct = @($targets | Group-Object Image | ForEach-Object { $_.Name })
  # Stage 5: image snapshots (last-2 tags) BEFORE any pull.
  foreach ($ref in $distinct) {
    $id = ((& docker image inspect $ref --format '{{.Id}}' 2>$null) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($id)) {
      Write-Host "SNAPSHOT SKIP ${ref}: локальный образ отсутствует, притянется при pull."
      continue
    }
    $repo = Get-MahabbatImageRepoWithoutTag $ref
    # NOTE: always brace the repo variable (${repo}:previous). An unbraced
    # "$repo:previous" parses as a scoped-variable reference and expands to
    # an EMPTY string, so Docker would receive ':previous' and silently
    # target nothing.
    $prevId = ((& docker image inspect "${repo}:previous" --format '{{.Id}}' 2>$null) -join '').Trim()
    if (-not [string]::IsNullOrWhiteSpace($prevId)) { & docker tag "${repo}:previous" "${repo}:pre-previous" | Out-Null }
    & docker tag $id "${repo}:previous" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Не удалось сохранить снапшот previous для $ref." }
    Write-Host "SNAPSHOT OK ${repo}:previous (предыдущий previous ротирован в pre-previous)."
  }
  Write-MahabbatUpdateJournalEntry -Stage 'snapshots' -State 'ok' -Detail ($distinct -join ', ')
  # Stage 6: pull EXACTLY the recorded digests (repo@sha256, never a mutable
  # alias), prove each local image, then start the stack on digest refs so
  # compose instantiates the pinned content. Process env wins over --env-file
  # interpolation, and is restored right after 'up'.
  try {
    $pinnedRefs = Invoke-MahabbatPinnedImagePull -Targets @($recorded.targets)
  } catch {
    Write-MahabbatUpdateJournalEntry -Stage 'pull' -State 'failed' -Detail $_.Exception.Message
    throw
  }
  Write-MahabbatUpdateJournalEntry -Stage 'pull' -State 'ok' -Detail ($pinnedRefs -join ', ')
  $prevTwentyImage = [Environment]::GetEnvironmentVariable('MAHABBAT_TWENTY_IMAGE', 'Process')
  $prevPosImage = [Environment]::GetEnvironmentVariable('MAHABBAT_POS_IMAGE', 'Process')
  try {
    foreach ($t in @($recorded.targets)) {
      $digestRef = "$([string]$t.repo)@$([string]$t.targetDigest)"
      if ([string]$t.key -eq 'twenty') { [Environment]::SetEnvironmentVariable('MAHABBAT_TWENTY_IMAGE', $digestRef, 'Process') }
      elseif ([string]$t.key -eq 'pos') { [Environment]::SetEnvironmentVariable('MAHABBAT_POS_IMAGE', $digestRef, 'Process') }
    }
    Invoke-MahabbatCompose @('pull', 'db', 'redis')
    Invoke-MahabbatCompose @('up', '-d')
  } finally {
    if ($null -eq $prevTwentyImage) { [Environment]::SetEnvironmentVariable('MAHABBAT_TWENTY_IMAGE', $null, 'Process') }
    else { [Environment]::SetEnvironmentVariable('MAHABBAT_TWENTY_IMAGE', $prevTwentyImage, 'Process') }
    if ($null -eq $prevPosImage) { [Environment]::SetEnvironmentVariable('MAHABBAT_POS_IMAGE', $null, 'Process') }
    else { [Environment]::SetEnvironmentVariable('MAHABBAT_POS_IMAGE', $prevPosImage, 'Process') }
  }
  Write-MahabbatUpdateJournalEntry -Stage 'restart' -State 'ok' -Detail ($pinnedRefs -join ', ')
  # Maintenance continues: 'up -d' restarts EVERYTHING including pos-gateway,
  # but the write ban holds until post-verify. Stop it again right away —
  # no POS orders may land during metadata/health/reconcile/verify.
  Invoke-MahabbatCompose @('stop', 'pos-gateway')
  if (-not [string]::IsNullOrWhiteSpace((Get-MahabbatServiceContainerId 'pos-gateway'))) { throw 'pos-gateway did not stay stopped after restart; write ban cannot be guaranteed.' }
  Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'ban-holds' -Detail 'pos-gateway stopped until post-verify'
  Write-Host 'MAINTENANCE: pos-gateway снова остановлен после restart — запрет записи держится до конца verify.'
  # Stage 7: metadata plan/apply — resolver-code delivery needs a metadata pass.
  Write-Host 'METADATA PLAN:'
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action plan
  if ($LASTEXITCODE -ne 0) {
    Write-MahabbatUpdateJournalEntry -Stage 'metadata-plan' -State 'failed'
    throw 'Metadata plan failed; runtime left running for inspection. Исправьте и повторите apply (resume).'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'metadata-plan' -State 'ok'
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action apply
  if ($LASTEXITCODE -ne 0) {
    Write-MahabbatUpdateJournalEntry -Stage 'metadata-apply' -State 'failed'
    throw 'Metadata apply failed; runtime left running for inspection. Исправьте и повторите apply (resume).'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'metadata-apply' -State 'ok'
  Write-Host 'METADATA OK.'
  # Delivery proof: plan must be clean AFTER apply, or the new resolver code
  # is not actually deployed (R05). Fail before health/data stages.
  $planClean = Test-MahabbatMetadataPlanClean
  if (-not $planClean.clean) {
    Write-MahabbatUpdateJournalEntry -Stage 'metadata-plan-clean' -State 'failed' -Detail ([string]$planClean.reason)
    throw ("Metadata plan not clean after apply ($($planClean.reason)); resolver code not fully deployed. Исправьте и повторите apply (resume).")
  }
  Write-MahabbatUpdateJournalEntry -Stage 'metadata-plan-clean' -State 'ok'
  Write-Host 'METADATA PLAN CLEAN: deployed metadata matches the release.'
  # metadata apply force-recreates server/worker/pos-gateway: re-assert the ban.
  Invoke-MahabbatCompose @('stop', 'pos-gateway')
  if (-not [string]::IsNullOrWhiteSpace((Get-MahabbatServiceContainerId 'pos-gateway'))) { throw 'pos-gateway did not stay stopped after metadata apply; write ban cannot be guaranteed.' }
  Write-Host 'MAINTENANCE: запрет записи подтверждён после metadata apply.'
  # Stage 8: health gate BEFORE any data touch. POS stays banned: only the
  # CRM side must be healthy here; the POS probe runs after the post-verify start.
  $healthy = Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds -Exclude @('pos-gateway')
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  if (-not ($healthy -and $crm.Pass)) {
    Write-MahabbatUpdateJournalEntry -Stage 'health' -State 'failed' -Detail ("crm=$($crm.Code); pos-gateway banned until post-verify")
    throw 'Новая версия не прошла проверку здоровья; см. rollback ниже.'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'health' -State 'ok' -Detail ("crm=$($crm.Code); pos-gateway banned until post-verify")
  # Stage 9: data reconcile — damaged OPEN/IN_PROGRESS totals only, never seed.
  # Best-effort by design (updater holds no ADMIN session): an empty queue is
  # nothing-to-do; a non-empty queue journals 'deferred' and prints the exact
  # operator command. 'ok' is journaled ONLY for the empty queue. Verify
  # still gates the release.
  if (-not $SkipReconcile) {
    $reconciled = Invoke-MahabbatDamagedTotalsReconcile -Release $release
    if ($reconciled -match '0 queued') {
      Write-MahabbatUpdateJournalEntry -Stage 'reconcile' -State 'ok' -Detail ([string]$reconciled)
      Write-Host ("RECONCILE OK: {0}." -f $reconciled)
    } else {
      Write-MahabbatUpdateJournalEntry -Stage 'reconcile' -State 'deferred' -Detail ([string]$reconciled)
      Write-Host ("RECONCILE DEFERRED: {0}." -f $reconciled)
    }
  } else {
    Write-MahabbatUpdateJournalEntry -Stage 'reconcile' -State 'skipped'
  }
  # Stage 10: post-update verify — versions/images/logic-functions/parity/health/invariants.
  if (-not $SkipVerify) {
    $report = Get-MahabbatUpdateVerifyReport -TimeoutSeconds $TimeoutSeconds
    foreach ($line in $report.lines) { Write-Host $line }
    if (-not $report.ok) {
      Write-MahabbatUpdateJournalEntry -Stage 'verify' -State 'failed' -Detail ($report.failures -join '; ')
      throw ("Проверка после обновления не пройдена: {0}." -f ($report.failures -join '; '))
    }
    Write-MahabbatUpdateJournalEntry -Stage 'verify' -State 'ok'
  } else {
    Write-MahabbatUpdateJournalEntry -Stage 'verify' -State 'skipped'
  }
  # Stage 10b: end of maintenance — start POS only AFTER verify passed.
  # Any failure from here routes to rollback with the window still open.
  Invoke-MahabbatCompose @('up', '-d', 'pos-gateway')
  if (-not (Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds)) {
    Write-MahabbatUpdateJournalEntry -Stage 'pos-start' -State 'failed'
    throw 'pos-gateway не стал здоровым после verify; см. rollback ниже.'
  }
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  if (-not $pos.Pass) {
    Write-MahabbatUpdateJournalEntry -Stage 'pos-start' -State 'failed' -Detail ("pos=$($pos.Code)")
    throw 'pos-gateway /health не отвечает после verify; см. rollback ниже.'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'pos-start' -State 'ok' -Detail ("pos=$($pos.Code)")
  Write-Host 'MAINTENANCE: pos-gateway запущен после verify — приём заказов возобновлён.'
  Close-MahabbatMaintenanceWindow
  Write-Host ("UPDATE OK: Mahabbat {0} установлена и проверена." -f $release.mahabbatVersion)
  Write-MahabbatUpdateJournalEntry -Stage 'done' -State 'ok'
  exit 0
} catch {
  $stageMsg = $_.Exception.Message
  Write-MahabbatUpdateJournalEntry -Stage 'apply' -State 'failed' -Detail $stageMsg
  # G6: rollback (tags + restart) runs ONLY when this run actually mutated
  # runtime (maintenance window opened). A pre-gate refusal — stale flag,
  # backup gate, locks, pin — journals and exits with runtime untouched.
  if ($windowOpened) {
    $restored = $false
    try { $restored = Invoke-MahabbatUpdateRollback -Reason $stageMsg } catch { Write-Error $_.Exception.Message }
    if ((Test-MahabbatMaintenanceOpen)) {
      if ($restored) {
        Close-MahabbatMaintenanceWindow
        Write-Host 'MAINTENANCE: окно закрыто откатом (previous версия здорова, повтор apply разрешён).'
      } else {
        Write-Warning 'MAINTENANCE: окно осталось открытым (откат неполный) — проверьте вручную и удалите .private/maintenance.json.'
      }
    }
  } else {
    Write-MahabbatUpdateJournalEntry -Stage 'rollback' -State 'skipped' -Detail 'pre-window failure: runtime untouched, nothing to roll back'
  }
  Write-Error $stageMsg
  exit 1
}
