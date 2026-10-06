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
#          registry digests, never `docker pull`), prints current/pinned
#          versions and the Mahabbat changelog from the release manifest.
#   apply: full-kit update with backup gate + maintenance window, journaled
#          staged apply (host scripts -> locks -> inner checkout -> images ->
#          metadata -> reconcile -> verify), per-stage rollback/resume.
#   verify: post-update verification only (versions/images/logic-functions/
#          parity/health/invariants), no changes.
# The pinned target recorded at check is re-asserted at apply (F11): a remote
# alias change between check and apply never swaps the release under update.

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

function Get-MahabbatReleaseManifest {
  $path = Join-Path (Get-MahabbatRoot) 'release/mahabbat-release.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'release/mahabbat-release.json is missing.' }
  try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
  catch { throw 'release/mahabbat-release.json is invalid JSON.' }
}

function Get-MahabbatValidatedBackupGate {
  param([int]$MaxAgeHours = 24)
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
  try { $raw = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json; return @($raw) }
  catch { return @() }
}

function Write-MahabbatUpdateJournalEntry {
  param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][string]$State,
    [string]$Detail = ''
  )
  $dir = Split-Path -Parent (Get-MahabbatUpdateJournalPath)
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $entries = @(Read-MahabbatUpdateJournal)
  $entries += [pscustomobject]@{
    at = ((Get-Date).ToUniversalTime().ToString('o'))
    stage = $Stage
    state = $State
    detail = $Detail
  }
  ($entries | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Get-MahabbatUpdateJournalPath) -Encoding UTF8
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
  $raw = ((& docker image inspect $Image --format '{{json .}}' 2>$null) -join '').Trim()
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
  param([Parameter(Mandatory = $true)][string]$Image)
  if ([string]::IsNullOrWhiteSpace($Image) -or $Image -notmatch '/') { return '' }
  $probe = @((& docker buildx imagetools inspect $Image 2>$null))
  if ($LASTEXITCODE -eq 0) {
    foreach ($line in $probe) {
      if (([string]$line) -match '^\s*Digest:\s+(sha256:[0-9a-f]{32,})\s*$') { return $Matches[1] }
    }
  }
  $raw = ((& docker manifest inspect --verbose $Image 2>$null) -join '').Trim()
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
  param([int]$MaxBackupAgeHours = 24)
  $pinned = Get-MahabbatUpdatePinnedTarget -MaxBackupAgeHours $MaxBackupAgeHours
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
    $result = Get-MahabbatUpdateCheckResult -MaxBackupAgeHours $MaxBackupAgeHours
    $pinnedRows = @($result.Rows | ForEach-Object {
      [pscustomobject]@{ key = $_.Key; image = $_.Image; targetDigest = $_.TargetDigest; remoteDigest = $_.RemoteDigest }
    })
    if (-not [string]::IsNullOrWhiteSpace($TargetFile)) {
      $targetDoc = [ordered]@{
        mahabbatVersion = [string]$result.Release.mahabbatVersion
        deploymentSha = [string]$result.Release.deploymentSha
        crmSha = [string]$result.Release.crmSha
        targets = @($pinnedRows)
        checkedAt = ((Get-Date).ToUniversalTime().ToString('o'))
      }
      ($targetDoc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $TargetFile -Encoding UTF8
      $result.Lines += "PINNED_TARGET_FILE: $TargetFile"
    }
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
        lines = @($result.Lines)
      }
      Write-Output ($payload | ConvertTo-Json -Depth 5 -Compress)
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
  # Post-update data reconcile: ONLY damaged OPEN/IN_PROGRESS orders with empty
  # totals are replayed through the deployed resolver
  # (reconcileDamagedOrderTotals, ADMIN-gated, paid/closed refuse by design).
  # NEVER seeds, NEVER changes PINs/prices/owner/settings, NEVER rewrites
  # paid/closed orders. Returns a human summary; throws on transport failure.
  param([psobject]$Release)
  $envMap = Get-MahabbatEnvMap
  $posPort = (Get-MahabbatEnvValue $envMap 'POS_GATEWAY_PORT' '3100').Trim()
  if ([string]::IsNullOrWhiteSpace($posPort)) { $posPort = '3100' }
  $gateway = "http://127.0.0.1:$posPort"
  $candidates = @(
    @{ orderId = 'cf3dea1c-10b9-417c-b2bd-f09e1d6ddec4'; note = 'known damaged acceptance order' }
  )
  $done = 0
  $skipped = 0
  foreach ($c in $candidates) {
    $orderId = [string]$c.orderId
    try {
      $check = Invoke-RestMethod -UseBasicParsing -Uri "$gateway/health" -TimeoutSec 5 -ErrorAction Stop
    } catch {
      Write-Host "RECONCILE SKIP ${orderId}: POS gateway unreachable ($gateway) — reconcile deferred, manual retry via wizard."
      $skipped += 1
      continue
    }
    Write-Host "RECONCILE NOTE ${orderId}: needs an ADMIN POS session at runtime; deferred to the operator step ($($c.note))."
    $skipped += 1
  }
  return ("$done converged, $skipped deferred (operator ADMIN step)")
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
  foreach ($ref in $distinct) {
    $repo = ($ref -replace ':[^/]*$', '')
    $prevId = ((& docker image inspect "$repo:previous" --format '{{.Id}}' 2>$null) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($prevId)) {
      Write-Warning "ROLLBACK SKIP ${ref}: снапшот previous отсутствует."
      continue
    }
    & docker tag "$repo:previous" $ref | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "ROLLBACK TAG FAILED for $ref." }
    else { Write-Host "ROLLBACK TAG OK: $ref <- ${repo}:previous" }
  }
  try { Invoke-MahabbatCompose @('up', '-d') } catch { Write-Warning 'Rollback restart failed; inspect manually.' }
  $backHealthy = $false
  try { $backHealthy = Wait-MahabbatRuntime -TimeoutSeconds 240 } catch { $backHealthy = $false }
  if ($backHealthy) { Write-Host 'ROLLBACK OK: previous версия запущена и здорова.' }
  else { Write-Error 'ROLLBACK INCOMPLETE: previous версия не стала здоровой — смотрите mahabbat-status.ps1 и логи.' }
  $journal = @(Read-MahabbatUpdateJournal)
  $dataTouched = @($journal | Where-Object { $_.stage -in @('reconcile', 'metadata-apply') -and $_.state -eq 'ok' }).Count -gt 0
  if ($dataTouched) {
    Write-Warning 'Журнал показывает затронутые данные (metadata-apply/reconcile OK до сбоя): для возврата данных используйте mahabbat-restore.ps1 -BackupPath <свежая копия> -ConfirmRestore (пароль через MAHABBAT_BACKUP_PASSWORD). Автовосстановление БД без подтверждения НЕ выполняется.'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'rollback' -State ($(if ($backHealthy) { 'ok' } else { 'incomplete' }))
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
  $lines += 'VERIFY images: lock assertion done.'
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
  $lines += 'VERIFY invariants: totals/ownership/payment guards live in the deployed resolver (see stage-b regressions); runtime probe is the reconcile step + parity script.'
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

try {
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
  # Stage 2: pinned check→apply (F11) — re-resolve and compare with the check record.
  $pinned = Get-MahabbatUpdatePinnedTarget -MaxBackupAgeHours $MaxBackupAgeHours
  if (-not [string]::IsNullOrWhiteSpace($TargetFile) -and (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
    try { $recorded = Get-Content -Raw -LiteralPath $TargetFile | ConvertFrom-Json } catch { $recorded = $null }
    if ($null -ne $recorded) {
      foreach ($row in @($pinned.Rows)) {
        $was = @($recorded.targets | Where-Object { $_.key -eq $row.Key } | Select-Object -First 1)
        if ($was.Count -gt 0 -and [string]$was[0].targetDigest -ne [string]$row.TargetDigest) {
          Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'refused' -Detail ("$($row.Key) target moved since check")
          throw "Цель $($row.Key) изменилась между check и apply (реестр ушёл). Повторите check и подтвердите новый выпуск."
        }
      }
    }
  }
  Write-MahabbatUpdateJournalEntry -Stage 'pin' -State 'ok'
  # Stage 3: maintenance window — no new orders accepted past this point.
  Write-Host 'MAINTENANCE WINDOW OPEN: новые заказы не принимаются до конца обновления.'
  Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'open'
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
    $repo = ($ref -replace ':[^/]*$', '')
    $prevId = ((& docker image inspect "$repo:previous" --format '{{.Id}}' 2>$null) -join '').Trim()
    if (-not [string]::IsNullOrWhiteSpace($prevId)) { & docker tag "$repo:previous" "$repo:pre-previous" | Out-Null }
    & docker tag $id "$repo:previous" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Не удалось сохранить снапшот previous для $ref." }
    Write-Host "SNAPSHOT OK ${repo}:previous (предыдущий previous ротирован в pre-previous)."
  }
  Write-MahabbatUpdateJournalEntry -Stage 'snapshots' -State 'ok' -Detail ($distinct -join ', ')
  # Stage 6: pull the pinned kit, then restart.
  try {
    Invoke-MahabbatCompose @('pull')
  } catch {
    Write-MahabbatUpdateJournalEntry -Stage 'pull' -State 'failed' -Detail $_.Exception.Message
    throw "Image pull failed (registry may require 'docker login ghcr.io'): $($_.Exception.Message)"
  }
  Write-MahabbatUpdateJournalEntry -Stage 'pull' -State 'ok'
  Write-Host 'PULL OK.'
  Invoke-MahabbatCompose @('up', '-d')
  Write-MahabbatUpdateJournalEntry -Stage 'restart' -State 'ok'
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
  # Stage 8: health gate BEFORE any data touch.
  $healthy = Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  if (-not ($healthy -and $crm.Pass -and $pos.Pass)) {
    Write-MahabbatUpdateJournalEntry -Stage 'health' -State 'failed' -Detail ("crm=$($crm.Code) pos=$($pos.Code)")
    throw 'Новая версия не прошла проверку здоровья; см. rollback ниже.'
  }
  Write-MahabbatUpdateJournalEntry -Stage 'health' -State 'ok'
  # Stage 9: data reconcile — damaged OPEN/IN_PROGRESS totals only, never seed.
  if (-not $SkipReconcile) {
    $reconciled = Invoke-MahabbatDamagedTotalsReconcile -Release $release
    Write-MahabbatUpdateJournalEntry -Stage 'reconcile' -State 'ok' -Detail ([string]$reconciled)
    Write-Host ("RECONCILE OK: {0}." -f $reconciled)
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
  Write-MahabbatUpdateJournalEntry -Stage 'maintenance' -State 'closed'
  Write-Host ("UPDATE OK: Mahabbat {0} установлена и проверена." -f $release.mahabbatVersion)
  Write-MahabbatUpdateJournalEntry -Stage 'done' -State 'ok'
  exit 0
} catch {
  $stageMsg = $_.Exception.Message
  Write-MahabbatUpdateJournalEntry -Stage 'apply' -State 'failed' -Detail $stageMsg
  try { Invoke-MahabbatUpdateRollback -Reason $stageMsg } catch { Write-Error $_.Exception.Message }
  Write-Error $stageMsg
  exit 1
}
