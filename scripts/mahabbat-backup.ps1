[CmdletBinding()]
param(
  [switch]$NonInteractive,
  [switch]$AllowPlaintext
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')

$pwBytes = $null
$manifestWritten = $false
$backupDir = ''
try {
  $pwRaw = Read-MahabbatBackupPassword
  if ([string]::IsNullOrEmpty($pwRaw) -and (-not $NonInteractive) -and [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_NONINTERACTIVE'))) {
    $first = Read-Host 'Пароль для шифрования копии (пусто = обычная копия без шифрования)' -AsSecureString
    try {
      $second = Read-Host 'Повторите пароль копии' -AsSecureString
      try {
        $a = Convert-MahabbatSecureStringToString -Secure $first
        $b = Convert-MahabbatSecureStringToString -Secure $second
        if ($a -cne $b) { throw 'Пароли копии не совпадают.' }
        if (($a.Length -gt 0) -and ($a.Length -lt $script:MahabbatBackupPasswordMinLength)) {
          throw 'Пароль для шифрования копии — минимум 10 символов. Пустое значение — обычная копия без шифрования.'
        }
        if ($a.Length -gt 0) { $pwRaw = $a }
      } finally {
        $second.Dispose()
      }
    } finally {
      $first.Dispose()
    }
  }
  if (-not [string]::IsNullOrEmpty($pwRaw)) {
    $pwBytes = [Text.Encoding]::UTF8.GetBytes($pwRaw)
  }
  $pwRaw = $null
  # Ночная копия: DPAPI machine-key под CurrentUser (трей делает Unprotect и
  # кладёт base64 в MAHABBAT_BACKUP_NIGHTLY_B64). Ручная — бумажный пароль.
  # Plaintext только с явным -AllowPlaintext (+ варнинг в манифест/консоль).
  $nightlyB64 = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_NIGHTLY_B64', 'Process')
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_NIGHTLY_B64', $null, 'Process')
  $nightlyUsed = $false
  if (($null -eq $pwBytes) -and (-not [string]::IsNullOrEmpty($nightlyB64))) {
    $nightlyUsed = $true
    try { $pwBytes = [Convert]::FromBase64String($nightlyB64) }
    finally { $nightlyB64 = $null }
    if ($pwBytes.Length -ne 32) { throw 'Ночной ключ повреждён.' }
  }
  if (($null -eq $pwBytes) -and (-not $AllowPlaintext) -and $NonInteractive) {
    throw 'Ночная копия требует DPAPI-ключ (.private/backup-nightly.dpapi) или бумажный пароль; plaintext только с -AllowPlaintext.'
  }
  Assert-MahabbatDockerEngine
  $missing = @(Test-MahabbatEnvironment)
  if ($missing.Count -gt 0) { throw "Missing required .env values: $($missing -join ', ')" }
  $inner = Get-MahabbatInnerState
  if (-not $inner.Match) { throw 'Inner repository does not match mahabbat-inner.lock.json.' }
  $dbContainer = Get-MahabbatServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($dbContainer)) { throw 'PostgreSQL container is not running. Start Mahabbat first.' }
  $dbState = Get-MahabbatContainerState $dbContainer
  if ($dbState.Health -ne 'healthy') { throw "PostgreSQL is not healthy ($($dbState.Health))." }

  $envMap = Get-MahabbatEnvMap
  $dbUser = Get-MahabbatEnvValue $envMap 'PG_DATABASE_USER' 'postgres'
  $dbName = Get-MahabbatEnvValue $envMap 'PG_DATABASE_NAME' 'default'
  $timestamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
  $backupRoot = Get-MahabbatBackupRoot
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
  $backupDir = Join-Path $backupRoot $timestamp
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  $dumpName = "mahabbat-$timestamp.dump"
  $dumpPath = Join-Path $backupDir 'database.dump'
  $containerDump = "/tmp/$dumpName"

  & docker exec $dbContainer sh -c "pg_dump -U '$dbUser' -d '$dbName' -Fc --no-owner --no-acl > '$containerDump'"
  if ($LASTEXITCODE -ne 0) { throw 'pg_dump failed.' }
  & docker cp "${dbContainer}:$containerDump" $dumpPath
  if ($LASTEXITCODE -ne 0) { throw 'Could not copy PostgreSQL dump out of the container.' }
  $validation = (& docker exec $dbContainer pg_restore --list $containerDump 2>$null) -join "`n"
  $valid = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($validation))
  & docker exec $dbContainer rm -f $containerDump 2>$null
  if (-not $valid) { throw 'pg_restore validation failed.' }
  # File state: server-local-data (uploads/.local-storage) rides with the DB
  # dump so a restore brings both back together. Best-effort tar from a
  # throwaway alpine container; an empty/missing volume still writes a marker.
  # Stage C: when the copy is encrypted, the tar is encrypted to
  # server-local-data.tar.gz.enc with the SAME password bytes (same
  # MHBE01/HMAC format as the dump) and covered by filesSha256 in the
  # manifest. Version-1 plaintext tars stay readable (legacy compat).
  $serverContainer = Get-MahabbatServiceContainerId 'server'
  $filesArchive = Join-Path $backupDir 'server-local-data.tar.gz'
  $filesEncPath = Join-Path $backupDir 'server-local-data.tar.gz.enc'
  $filesIncluded = $false
  if (-not [string]::IsNullOrWhiteSpace($serverContainer)) {
    & docker run --rm --volumes-from $serverContainer -v "${backupDir}:/backup-out" alpine:3.21 tar -czf /backup-out/server-local-data.tar.gz -C /app/packages/twenty-server/.local-storage . 2>$null
    if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $filesArchive -PathType Leaf)) { $filesIncluded = $true }
  }
  if ((-not $filesIncluded)) {
    # Fallback: server container absent (DB-only stand) — snapshot the named
    # volume directly through a throwaway helper (same bytes, same tar).
    try {
      $volProbe = Get-MahabbatServiceContainerId 'db'
      if (-not [string]::IsNullOrWhiteSpace($volProbe)) {
        $inspRaw = ((& docker inspect $volProbe --format '{{json .Config.Labels}}' 2>$null) -join '').Trim()
        $projM2 = [regex]::Match($inspRaw, 'com[.]docker[.]compose[.]project[^A-Za-z0-9_-]+([A-Za-z0-9][A-Za-z0-9_-]*)')
        if ($projM2.Success) {
          $filesVol = ($projM2.Groups[1].Value + '_server-local-data')
          & docker run --rm -v ("${filesVol}:/srv:ro") -v "${backupDir}:/backup-out" alpine:3.21 tar -czf /backup-out/server-local-data.tar.gz -C /srv . 2>$null
          if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $filesArchive -PathType Leaf)) { $filesIncluded = $true }
        }
      }
    } catch { }
  }
  if (-not $filesIncluded) {
    [IO.File]::WriteAllText((Join-Path $backupDir 'server-local-data.empty'), "server-local-data snapshot unavailable at $timestamp (server container not running or empty volume).")
  }

  $encrypted = ($null -ne $pwBytes)
  $dumpFile = 'database.dump'
  $encPath = Join-Path $backupDir 'database.dump.enc'
  $encryptionBlock = $null
  if ($encrypted -and $filesIncluded) {
    # Same password bytes protect the files tar (same MHBE01 format).
    # Verify round-trip BEFORE shredding the plaintext tar: HMAC check via
    # decrypt to temp + tar -tzf listing. Wrong-password/corrupt refuses here,
    # before the manifest is written.
    Protect-MahabbatDump -PlainPath $filesArchive -EncPath $filesEncPath -PasswordBytes $pwBytes
    $filesVerifyLocal = Join-Path ([IO.Path]::GetTempPath()) "mahabbat-verify-files-$timestamp.tar.gz"
    if (Test-Path -LiteralPath $filesVerifyLocal) { Remove-Item -LiteralPath $filesVerifyLocal -Force }
    try {
      Unprotect-MahabbatDump -EncPath $filesEncPath -OutPath $filesVerifyLocal -PasswordBytes $pwBytes
      $filesList = (& tar -tzf $filesVerifyLocal 2>$null) -join "`n"
      if (($LASTEXITCODE -ne 0) -or [string]::IsNullOrWhiteSpace($filesList)) {
        throw 'Копия файлов не удалась при проверке шифрования.'
      }
    } finally {
      Remove-MahabbatFileSecure -Path $filesVerifyLocal
    }
    Remove-MahabbatFileSecure -Path $filesArchive
  }
  if ($encrypted) {
    $plainBytes = (Get-Item -LiteralPath $dumpPath).Length
    Protect-MahabbatDump -PlainPath $dumpPath -EncPath $encPath -PasswordBytes $pwBytes
    $verifyName = "/tmp/mahabbat-verify-$timestamp.dump"
    $verifyLocal = Join-Path ([IO.Path]::GetTempPath()) "mahabbat-verify-$timestamp.dump"
    if (Test-Path -LiteralPath $verifyLocal) { Remove-Item -LiteralPath $verifyLocal -Force }
    try {
      Unprotect-MahabbatDump -EncPath $encPath -OutPath $verifyLocal -PasswordBytes $pwBytes
      & docker cp $verifyLocal "${dbContainer}:$verifyName"
      if ($LASTEXITCODE -ne 0) { throw 'Копия не удалась при проверке шифрования.' }
      $verifyList = (& docker exec $dbContainer pg_restore --list $verifyName 2>$null) -join "`n"
      if (($LASTEXITCODE -ne 0) -or [string]::IsNullOrWhiteSpace($verifyList)) {
        throw 'Копия не удалась при проверке шифрования.'
      }
    } finally {
      Remove-MahabbatFileSecure -Path $verifyLocal
      & docker exec $dbContainer rm -f $verifyName 2>$null
    }
    Remove-MahabbatFileSecure -Path $dumpPath
    $dumpFile = 'database.dump.enc'
    $encryptionBlock = [ordered]@{
      cipher = 'AES-256-CBC+HMAC-SHA256'
      kdf = 'PBKDF2-HMAC-SHA256'
      iterations = $script:MahabbatBackupPbkdf2Iterations
      magic = $script:MahabbatBackupMagic
      headerBytes = $script:MahabbatBackupHeaderBytes
      plaintextBytes = $plainBytes
      ciphertextSha256 = (Get-MahabbatFileSha256Hex -Path $encPath)
      passwordMinLength = $script:MahabbatBackupPasswordMinLength
    }
  }

  $outerHead = ((& git -C (Get-MahabbatRoot) rev-parse HEAD 2>$null) -join '').Trim()
  if ([string]::IsNullOrWhiteSpace($outerHead)) { $outerHead = '<uncommitted>' }
  $filesField = 'server-local-data.tar.gz'
  $filesDigestField = $null
  if ($encrypted -and $filesIncluded) {
    $filesField = 'server-local-data.tar.gz.enc'
    $filesDigestField = (Get-MahabbatFileSha256Hex -Path $filesEncPath)
  } elseif (-not $filesIncluded) {
    $filesField = 'server-local-data.empty (snapshot unavailable)'
  }
  $manifest = [ordered]@{
    backupVersion = 2
    timestamp = (Get-Date).ToString('o')
    innerSha = $inner.Actual
    outerSha = $outerHead
    database = [ordered]@{ container = 'db'; name = $dbName; user = $dbUser }
    dump = $dumpFile
    encrypted = [bool]$encrypted
    validation = 'pg_restore --list passed inside the PostgreSQL 16 container'
    restoreNotes = 'Stop server, worker, and POS first. Restore only as an explicit operator action using mahabbat-restore.ps1.'
    files = $filesField
    backupRoot = $backupRoot
    retentionKept = (Get-MahabbatBackupRetentionCount)
  }
  if ($null -ne $filesDigestField) { $manifest.filesSha256 = $filesDigestField }
  if ($encrypted) {
    $manifest.encryption = $encryptionBlock
    if ($nightlyUsed) {
      $manifest.encryption.keySource = 'DPAPI-CurrentUser (.private/backup-nightly.dpapi)'
      $manifest.validation = 'pg_restore --list passed on decrypted plaintext inside the PostgreSQL 16 container before shredding (nightly DPAPI key)'
      $manifest.restoreNotes = 'Nightly DPAPI copy: restores automatically on this Windows user; manual restore needs the same user profile. No paper password exists for this copy.'
    } else {
      $manifest.validation = 'pg_restore --list passed on decrypted plaintext inside the PostgreSQL 16 container before shredding'
      $manifest.restoreNotes = 'Encrypted. Restore with mahabbat-restore.ps1 -BackupPath <dir> -ConfirmRestore, then enter the copy password. No recovery without the password.'
    }
  }
  [IO.File]::WriteAllText((Join-Path $backupDir 'backup-manifest.json'), ($manifest | ConvertTo-Json -Depth 5))
  $manifestWritten = $true
  if ($encrypted -and (-not $nightlyUsed)) {
    # Recovery sheet: бумажная памятка рядом с шифр-копией (без секретов).
    $sheet = @(
      'MAHABBAT RECOVERY SHEET',
      "Дата копии: $($manifest.timestamp)",
      "Папка: $backupDir",
      'Шифрование: AES-256-CBC+HMAC-SHA256, PBKDF2-HMAC-SHA256 200000',
      "SHA256(enc): $($manifest.encryption.ciphertextSha256)",
      '',
      'Пароль копии: ______________________________ (10+ символов, хранится отдельно)',
      '',
      'Проверить пароль БЕЗ восстановления:',
      "  powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-verify-password.ps1 -BackupPath '$backupDir'",
      '',
      'Восстановить (сотрёт живую базу, остановит кассу/CRM/печать):',
      "  powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-restore.ps1 -BackupPath '$backupDir' -ConfirmRestore",
      'Перед восстановлением: свежая копия + dry-run list см. RUNNING_MAHABBAT.md.'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $backupDir 'RECOVERY-SHEET.txt'), $sheet)
  }
  if ($encrypted -and $nightlyUsed) {
    Write-Host "Backup created (encrypted, nightly DPAPI): $backupDir"
    Write-Host 'Ночная копия зашифрована ключом этого пользователя Windows и проверена.'
  } elseif ($encrypted) {
    Write-Host "Backup created (encrypted): $backupDir"
    Write-Host 'Копия зашифрована и проверена. Без пароля восстановить нельзя.'
  } else {
    Write-Host "Backup created: $backupDir"
    Write-Host 'Manifest and dump validated; credentials are not included.'
    if ($AllowPlaintext) { Write-Warning 'Обычная копия БЕЗ шифрования (явный -AllowPlaintext). Для ручной копии задайте пароль.' }
    else { Write-Host 'Обычная копия без шифрования. Для ручной копии задайте пароль.' }
  }
  $pruned = Invoke-MahabbatBackupRetention -BackupRoot $backupRoot
  if ($pruned -gt 0) { Write-Host "Retention: kept $(Get-MahabbatBackupRetentionCount) newest, pruned $pruned older copy(ies) in $backupRoot." }
  else { Write-Host "Retention: keeping newest $(Get-MahabbatBackupRetentionCount) in $backupRoot." }
} catch {
  if ((-not $manifestWritten) -and (-not [string]::IsNullOrEmpty($backupDir)) -and (Test-Path -LiteralPath $backupDir)) {
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Error $_.Exception.Message
  exit 1
} finally {
  if ($null -ne $pwBytes) { Clear-MahabbatByteArray -Bytes $pwBytes }
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
}
