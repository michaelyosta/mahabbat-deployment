[CmdletBinding()]
param(
  [ValidateSet('check', 'apply')][string]$Action = 'check',
  [switch]$Json,
  [int]$MaxBackupAgeHours = 24,
  [int]$TimeoutSeconds = 420
)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

# Mahabbat update: explicit-only image updates, never silent-auto.
#   check: read-only. Compares local digests against GHCR (manifest read,
#          never `docker pull`), prints current/remote versions and the first
#          3 CHANGELOG lines from the local image description label.
#   apply: requires a fresh backup (refuses without one), snapshots last-2
#          local tags (:previous/:pre-previous), pulls, starts, health-gates,
#          and auto-rolls back to :previous on failure.
# Target refs resolve via NetSetupCI contract: MAHABBAT_TWENTY_IMAGE /
# MAHABBAT_POS_IMAGE overrides, else resolved `docker compose config --images`
# (incl. Get-MahabbatComposeServiceImages when present), else
# ghcr.io/<MAHABBAT_IMAGE_OWNER-lower>/ defaults.

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

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

function Get-MahabbatUpdateChangelogLines {
  param([psobject]$Local)
  $found = @(((([string]$Local.Description) -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -First 3))
  if ($found.Count -gt 0) { return $found }
  $fallback = @()
  if (-not [string]::IsNullOrWhiteSpace([string]$Local.Version)) { $fallback += "version $([string]$Local.Version)" }
  if (-not [string]::IsNullOrWhiteSpace([string]$Local.Revision)) { $fallback += "revision $([string]$Local.Revision)" }
  if ($fallback.Count -gt 0) { return $fallback }
  return @('Описание изменения недоступно локально (нет label org.opencontainers.image.description).')
}

function Get-MahabbatUpdateCheckResult {
  param([int]$MaxBackupAgeHours = 24)
  $targets = Get-MahabbatUpdateTargets
  $lines = @()
  $rows = @()
  foreach ($t in $targets) {
    $local = Get-MahabbatUpdateLocalInfo -Image $t.Image
    $remote = ''
    if (Test-MahabbatDockerEngine) { $remote = Get-MahabbatUpdateRemoteDigest -Image $t.Image }
    $status = 'unknown'
    if (-not [string]::IsNullOrWhiteSpace($remote)) {
      if (-not $local.Present) { $status = 'yes' }
      elseif ((-not [string]::IsNullOrWhiteSpace($local.Digest)) -and ($local.Digest -eq $remote)) { $status = 'no' }
      elseif (-not [string]::IsNullOrWhiteSpace($local.Digest)) { $status = 'yes' }
    }
    $rows += [pscustomobject]@{
      Key = $t.Key; Label = $t.Label; Image = $t.Image
      LocalPresent = $local.Present; LocalDigest = $local.Digest
      LocalCreated = $local.Created; RemoteDigest = $remote; Status = $status
    }
    $localText = 'absent'
    if ($local.Present) {
      $localText = Get-MahabbatUpdateDigestShort $local.Digest
      if ([string]::IsNullOrWhiteSpace($localText)) { $localText = 'local-build' }
      if (-not [string]::IsNullOrWhiteSpace($local.Created)) { $localText += " ($($local.Created))" }
    }
    $remoteText = 'unknown (registry недоступен — нужен docker login ghcr.io)'
    if (-not [string]::IsNullOrWhiteSpace($remote)) { $remoteText = Get-MahabbatUpdateDigestShort $remote }
    $statusText = switch ($status) { 'yes' { 'UPDATE AVAILABLE' } 'no' { 'up-to-date' } default { 'unknown' } }
    $lines += "UPDATE $($t.Key) ($($t.Label)): $($t.Image)"
    $lines += "  LOCAL: $localText"
    $lines += "  REMOTE: $remoteText"
    $lines += "  STATUS: $statusText"
  }
  $overall = 'unknown'
  if (@($rows | Where-Object { $_.Status -eq 'yes' }).Count -gt 0) { $overall = 'yes' }
  elseif (@($rows | Where-Object { $_.Status -eq 'unknown' }).Count -eq 0) { $overall = 'no' }
  $backup = Get-MahabbatUpdateBackupState -MaxAgeHours $MaxBackupAgeHours
  $backupText = 'no'
  if ($backup.Fresh) { $backupText = "yes ($($backup.Path), возраст $($backup.AgeHours) ч)" }
  else { $backupText = "no ($($backup.Reason))" }
  $twenty = $rows | Where-Object { $_.Key -eq 'twenty' } | Select-Object -First 1
  $currentText = $twenty.Image
  if ($twenty.LocalPresent -and (-not [string]::IsNullOrWhiteSpace($twenty.LocalDigest))) {
    $currentText += ' @' + (Get-MahabbatUpdateDigestShort $twenty.LocalDigest)
  }
  if (-not [string]::IsNullOrWhiteSpace($twenty.LocalCreated)) { $currentText += " ($($twenty.LocalCreated))" }
  $availableText = 'unknown (registry недоступен)'
  if (-not [string]::IsNullOrWhiteSpace($twenty.RemoteDigest)) {
    $availableText = $twenty.Image + ' @' + (Get-MahabbatUpdateDigestShort $twenty.RemoteDigest)
  }
  $twentyLocal = Get-MahabbatUpdateLocalInfo -Image $twenty.Image
  $changelog = @(Get-MahabbatUpdateChangelogLines $twentyLocal)
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
  }
}


if ($Action -eq 'check') {
  try {
    $result = Get-MahabbatUpdateCheckResult -MaxBackupAgeHours $MaxBackupAgeHours
    if ($Json) {
      $payload = [ordered]@{
        ok = $true
        updateAvailable = $result.Overall
        current = $result.Current
        available = $result.Available
        backupFresh = $result.Backup.Fresh
        backupPath = $result.Backup.Path
        changelog = @($result.Changelog)
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

try {
  Assert-MahabbatDockerEngine
  $missing = @(Test-MahabbatEnvironment)
  if ($missing.Count -gt 0) { throw "Missing required .env values: $($missing -join ', ')" }
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw "Inner repository is missing at $($inner.Path). Run mahabbat-bootstrap.ps1." }
  if (-not $inner.Match) { throw "Inner HEAD does not match mahabbat-inner.lock.json. Expected $($inner.Expected), actual $($inner.Actual)." }
  if ($inner.Dirty) { throw 'Inner repository has uncommitted changes. Resolve them before updating.' }
  if (-not (Test-MahabbatComposeConfig)) { throw 'docker compose config validation failed.' }
  $targets = Get-MahabbatUpdateTargets
  $backup = Get-MahabbatUpdateBackupState -MaxAgeHours $MaxBackupAgeHours
  if (-not $backup.Fresh) {
    throw "Обновление запрещено без свежей резервной копии (не старше $MaxBackupAgeHours ч): $($backup.Reason). Сделайте копию и повторите."
  }
  Write-Host "BACKUP GATE OK: $($backup.Path) (возраст $($backup.AgeHours) ч)."
  Assert-MahabbatImageDigests
  $distinct = @($targets | Group-Object Image | ForEach-Object { $_.Name })
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
  try {
    Invoke-MahabbatCompose @('pull')
  } catch {
    throw "Image pull failed (registry may require 'docker login ghcr.io'): $($_.Exception.Message)"
  }
  Write-Host 'PULL OK.'
  Invoke-MahabbatCompose @('up', '-d')
  $healthy = Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds
  $crm = Test-MahabbatUrl 'http://localhost:3000/healthz' @(200)
  $pos = Test-MahabbatUrl 'http://localhost:3100/health' @(200)
  if ($healthy -and $crm.Pass -and $pos.Pass) {
    Write-Host 'UPDATE OK: новая версия запущена и здорова.'
    foreach ($ref in $distinct) {
      $fresh = Get-MahabbatUpdateLocalInfo -Image $ref
      Write-Host "UPDATE NEW ${ref} @$(Get-MahabbatUpdateDigestShort $fresh.Digest)"
    }
    exit 0
  }
  Write-Warning 'Новая версия не прошла проверку здоровья — откатываюсь на previous.'
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
  Invoke-MahabbatCompose @('up', '-d')
  $backHealthy = Wait-MahabbatRuntime -TimeoutSeconds $TimeoutSeconds
  if ($backHealthy) { Write-Host 'ROLLBACK OK: previous версия запущена и здорова.' }
  else { Write-Error 'ROLLBACK INCOMPLETE: previous версия не стала здоровой — смотрите mahabbat-status.ps1 и логи.' }
  throw 'Обновление не прошло проверку здоровья; выполнен откат на previous.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
