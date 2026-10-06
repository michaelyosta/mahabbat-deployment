[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BackupPath,
  [switch]$ConfirmRestore
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-validate.ps1')

function Read-MahabbatRestorePassword {
  param([string]$Prompt = 'Пароль копии')
  $envPw = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', 'Process')
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
  if (-not [string]::IsNullOrEmpty($envPw)) { return $envPw }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $secure = Read-Host $Prompt -AsSecureString
    try {
      $plain = Convert-MahabbatSecureStringToString -Secure $secure
    } finally {
      $secure.Dispose()
    }
    if (-not [string]::IsNullOrEmpty($plain)) { return $plain }
    if ($attempt -lt 3) { Write-Host 'Пароль не введён, попробуйте ещё раз.' }
  }
  return ''
}

$pwBytes = $null
$tempDump = ''
$tempFiles = ''
try {
  $backupDir = [IO.Path]::GetFullPath($BackupPath)
  # Stage C preflight: full manifest + payload + integrity validation BEFORE any
  # password prompt, decrypt, container stop or volume change. Refuses with a
  # named defect; nothing is modified on failure.
  $preflight = Test-MahabbatBackupManifest -BackupDir $backupDir
  if (-not $preflight.Ok) { throw $preflight.Reason }
  $manifest = $preflight.Manifest
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  $isEncrypted = $false
  if ($manifest.PSObject.Properties.Name -contains 'encrypted') {
    try { $isEncrypted = [bool]$manifest.encrypted } catch { $isEncrypted = $false }
  } elseif ($manifest.PSObject.Properties.Name -contains 'encryption') {
    $isEncrypted = $true
  }
  $encPath = Join-Path $backupDir 'database.dump.enc'
  $plainPath = Join-Path $backupDir 'database.dump'
  if ($isEncrypted) {
    Write-Host 'Backup is ENCRYPTED (AES-256-CBC+HMAC, PBKDF2-SHA256 200k).'
  }
  Write-Host "Backup timestamp: $($manifest.timestamp)"
  Write-Host "Backup inner SHA: $($manifest.innerSha)"
  Write-Host 'This operation will overwrite the live PostgreSQL database after stopping application services.'
  if (-not $ConfirmRestore) {
    Write-Host 'Refusing to restore without explicit -ConfirmRestore (confirmed in the wizard/tray dialog).'
    exit 2
  }

  $restoreDumpPath = $plainPath
  if ($isEncrypted) {
    $keySource = ''
    try {
      if (($manifest.PSObject.Properties.Name -contains 'encryption') -and ($null -ne $manifest.encryption) -and ($manifest.encryption.PSObject.Properties.Name -contains 'keySource')) {
        $keySource = [string]$manifest.encryption.keySource
      }
    } catch { $keySource = '' }
    if ($keySource -like 'DPAPI*') {
      # Ночная копия: пароль не спрашиваем — ключ расшифровывает DPAPI.
      Write-Host 'Nightly DPAPI copy: unlocking with this Windows user key.'
      $keyBytes = Get-MahabbatNightlyBackupKeyBytes
      try {
        $pwBytes = $keyBytes
        $keyBytes = $null
        $tempDump = Join-Path ([IO.Path]::GetTempPath()) ('mahabbat-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.dump')
        Unprotect-MahabbatDump -EncPath $encPath -OutPath $tempDump -PasswordBytes $pwBytes
        $restoreDumpPath = $tempDump
      } catch {
        if ($null -ne $keyBytes) { Clear-MahabbatByteArray -Bytes $keyBytes }
        throw
      }
    } else {
      $pwRaw = Read-MahabbatRestorePassword
      if ([string]::IsNullOrEmpty($pwRaw)) {
        Write-Host 'Пароль не введён. Восстановление отменено.'
        exit 2
      }
      $pwBytes = [Text.Encoding]::UTF8.GetBytes($pwRaw)
      $pwRaw = $null
      $tempDump = Join-Path ([IO.Path]::GetTempPath()) ('mahabbat-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.dump')
      Unprotect-MahabbatDump -EncPath $encPath -OutPath $tempDump -PasswordBytes $pwBytes
      $restoreDumpPath = $tempDump
    }
  }

  Assert-MahabbatDockerEngine
  $dbContainer = Get-MahabbatServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($dbContainer)) { throw 'PostgreSQL container is not running.' }
  $envMap = Get-MahabbatEnvMap
  $dbUser = Get-MahabbatEnvValue $envMap 'PG_DATABASE_USER' 'postgres'
  $dbName = Get-MahabbatEnvValue $envMap 'PG_DATABASE_NAME' 'default'
  Invoke-MahabbatCompose @('stop', 'server', 'worker', 'pos-gateway')
  $containerDump = '/tmp/mahabbat-restore.dump'
  & docker cp $restoreDumpPath "${dbContainer}:$containerDump"
  if ($LASTEXITCODE -ne 0) { throw 'Could not copy dump into PostgreSQL container.' }
  & docker exec $dbContainer pg_restore --clean --if-exists --exit-on-error --no-owner --no-acl -U $dbUser -d $dbName $containerDump
  $restoreExit = $LASTEXITCODE
  & docker exec $dbContainer rm -f $containerDump 2>$null
  if ($restoreExit -ne 0) { throw 'pg_restore failed; application services remain stopped for inspection.' }
  # Files restore (Stage C): server/worker/pos-gateway are STOPPED above, so
  # exec/cp into server is impossible — restore through the named volume via
  # a throwaway helper container. Layout: wipe the volume target, then unpack
  # the verified tar. ANY failure here is fatal (exit 1, services stay
  # stopped for inspection) — never a warning + success message.
  $tempFiles = ''
  $filesEncArchive = Join-Path $backupDir 'server-local-data.tar.gz.enc'
  $filesPlainArchive = Join-Path $backupDir 'server-local-data.tar.gz'
  $filesSourceTar = $null
  $filesField = ''
  try { if ($null -ne $manifest.files) { $filesField = [string]$manifest.files } } catch { $filesField = '' }
  if ((Test-Path -LiteralPath $filesEncArchive -PathType Leaf) -or ($filesField -match 'server-local-data.tar.gz.enc')) {
    if (-not (Test-Path -LiteralPath $filesEncArchive -PathType Leaf)) { throw 'manifest ссылается на server-local-data.tar.gz.enc, но файла нет — восстановление файлов невозможно.' }
    if ($null -eq $pwBytes) { throw 'Зашифрованный архив файлов требует тот же пароль копии.' }
    $filesDigestExpect = ''
    try {
      if (($manifest.PSObject.Properties.Name -contains 'filesSha256') -and ($null -ne $manifest.filesSha256)) { $filesDigestExpect = ([string]$manifest.filesSha256).Trim() }
    } catch { $filesDigestExpect = '' }
    if (-not [string]::IsNullOrWhiteSpace($filesDigestExpect)) {
      $filesDigestActual = (Get-MahabbatFileSha256Hex -Path $filesEncArchive).ToLowerInvariant()
      if ($filesDigestActual -cne $filesDigestExpect.ToLowerInvariant()) { throw 'Архив файлов не совпадает с manifest (SHA256) — файл повреждён или подменён.' }
    }
    $tempFiles = Join-Path ([IO.Path]::GetTempPath()) ('mahabbat-restore-files-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.tar.gz')
    Unprotect-MahabbatDump -EncPath $filesEncArchive -OutPath $tempFiles -PasswordBytes $pwBytes
    $filesSourceTar = $tempFiles
  } elseif (Test-Path -LiteralPath $filesPlainArchive -PathType Leaf) {
    # Plaintext tar (v2 plaintext copies now carry filesSha256 too; legacy
    # v1 without the digest skips the check — backward compat).
    $plainDigestExpect = ''
    try {
      if (($manifest.PSObject.Properties.Name -contains 'filesSha256') -and ($null -ne $manifest.filesSha256)) { $plainDigestExpect = ([string]$manifest.filesSha256).Trim() }
    } catch { $plainDigestExpect = '' }
    $plainReferenced = (($filesField -match 'server-local-data\.tar\.gz') -and (-not ($filesField -match '\.enc')))
    if ($plainReferenced -and (-not [string]::IsNullOrWhiteSpace($plainDigestExpect))) {
      $plainDigestActual = (Get-MahabbatFileSha256Hex -Path $filesPlainArchive).ToLowerInvariant()
      if ($plainDigestActual -cne $plainDigestExpect.ToLowerInvariant()) { throw 'Архив файлов не совпадает с manifest (SHA256) — файл повреждён или подменён.' }
    }
    $filesSourceTar = $filesPlainArchive
  } elseif (Test-Path -LiteralPath (Join-Path $backupDir 'server-local-data.empty') -PathType Leaf) {
    Write-Host 'Backup has no files archive (server-local-data.empty marker); file volume left untouched.'
  } else {
    Write-Host 'No server-local-data archive in this backup; file volume left untouched.'
  }
  if ($null -ne $filesSourceTar) {
    # Volume selection: THIS compose project first (db container label
    # com.docker.compose.project), so a host with both the live stack and an
    # isolated stand restores into its own volume. The global listing is only
    # a fallback and refuses on ambiguity instead of picking the first match.
    $targetVolume = ''
    try {
      $dbIdProbe = Get-MahabbatServiceContainerId 'db'
      if (-not [string]::IsNullOrWhiteSpace($dbIdProbe)) {
        $inspectRaw = ((& docker inspect $dbIdProbe --format '{{json .Config.Labels}}' 2>$null) -join '').Trim()
        $projM = [regex]::Match($inspectRaw, 'com[.]docker[.]compose[.]project[^A-Za-z0-9_-]+([A-Za-z0-9][A-Za-z0-9_-]*)')
        if ($projM.Success) { $targetVolume = ($projM.Groups[1].Value + '_server-local-data') }
      }
    } catch { $targetVolume = '' }
    if ([string]::IsNullOrWhiteSpace($targetVolume)) {
      try {
        $volNames = @((& docker volume ls --format '{{.Name}}' 2>$null))
        $candidates = @($volNames | Where-Object { $_ -match 'server-local-data$' })
        if ($candidates.Count -eq 1) { $targetVolume = [string]$candidates[0] }
        elseif ($candidates.Count -gt 1) { throw 'Several server-local-data volumes: ambiguous target; refusing file restore.' }
      } catch {
        if ($_.Exception.Message -match 'Several server-local-data volumes') { throw }
        $targetVolume = ''
      }
    }
    if ([string]::IsNullOrWhiteSpace($targetVolume)) { throw 'Не найден volume server-local-data — восстановление файлов невозможно.' }
    $stageDir = Join-Path ([IO.Path]::GetTempPath()) ('mahabbat-restore-stage-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    try {
      Copy-Item -LiteralPath $filesSourceTar -Destination (Join-Path $stageDir 'payload.tar.gz') -Force
      & docker run --rm -v ("{0}:/target" -f $targetVolume) -v ("{0}:/stage:ro" -f $stageDir) alpine:3.21 sh -c 'rm -rf /target/.local-restore-tmp && mkdir -p /target/.local-restore-tmp && tar -xzf /stage/payload.tar.gz -C /target/.local-restore-tmp && rm -rf /target/lost+found 2>/dev/null; rm -rf /target/* 2>/dev/null; cp -a /target/.local-restore-tmp/. /target/ && rm -rf /target/.local-restore-tmp'
      if ($LASTEXITCODE -ne 0) { throw 'Восстановление файлов в volume server-local-data не удалось; БД уже восстановлена, сервисы остановлены для проверки.' }
      Write-Host 'server-local-data restored from the same backup (volume replace via helper container).'
    } finally {
      Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Invoke-MahabbatCompose @('start', 'server', 'worker', 'pos-gateway')
  Write-Host 'Restore completed. Run mahabbat-start.ps1 and verify runtime parity/reconciliation.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
} finally {
  if (-not [string]::IsNullOrEmpty($tempDump)) { Remove-MahabbatFileSecure -Path $tempDump }
  if (-not [string]::IsNullOrEmpty($tempFiles)) { Remove-MahabbatFileSecure -Path $tempFiles }
  if ($null -ne $pwBytes) { Clear-MahabbatByteArray -Bytes $pwBytes }
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
}
