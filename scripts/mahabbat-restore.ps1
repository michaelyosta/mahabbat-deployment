[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BackupPath,
  [switch]$ConfirmRestore
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')

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
try {
  $backupDir = [IO.Path]::GetFullPath($BackupPath)
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Backup must contain backup-manifest.json and a dump file.'
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $isEncrypted = $false
  if ($manifest.PSObject.Properties.Name -contains 'encrypted') {
    $isEncrypted = [bool]$manifest.encrypted
  } elseif ($manifest.PSObject.Properties.Name -contains 'encryption') {
    $isEncrypted = $true
  }
  if ($isEncrypted) {
    if (([string]$manifest.dump) -ne 'database.dump.enc') {
      throw 'Манифест копии не соответствует файлу database.dump.enc.'
    }
  } else {
    if (([string]$manifest.dump) -ne 'database.dump') {
      throw 'Манифест копии не соответствует файлу database.dump.'
    }
  }
  $encPath = Join-Path $backupDir 'database.dump.enc'
  $plainPath = Join-Path $backupDir 'database.dump'
  if ($isEncrypted) {
    if (-not (Test-Path -LiteralPath $encPath -PathType Leaf)) {
      throw 'Зашифрованная копия должна содержать database.dump.enc.'
    }
    Write-Host 'Backup is ENCRYPTED (AES-256-CBC+HMAC, PBKDF2-SHA256 200k).'
    if (($manifest.PSObject.Properties.Name -contains 'encryption') -and ($null -ne $manifest.encryption.ciphertextSha256)) {
      $actualDigest = (Get-MahabbatFileSha256Hex -Path $encPath).ToLowerInvariant()
      $expectedDigest = ([string]$manifest.encryption.ciphertextSha256).ToLowerInvariant()
      if ($actualDigest -cne $expectedDigest) { throw 'Неверный пароль или повреждённый файл.' }
    }
  } else {
    if (-not (Test-Path -LiteralPath $plainPath -PathType Leaf)) {
      throw 'Backup must contain backup-manifest.json and database.dump.'
    }
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
    $keySource = [string]$manifest.encryption.keySource
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
  $filesArchive = Join-Path $backupDir 'server-local-data.tar.gz'
  if (Test-Path -LiteralPath $filesArchive -PathType Leaf) {
    $serverContainer = Get-MahabbatServiceContainerId 'server'
    if (-not [string]::IsNullOrWhiteSpace($serverContainer)) {
      $tmpTar = '/tmp/mahabbat-restore-local-data.tar.gz'
      & docker cp $filesArchive "${serverContainer}:$tmpTar"
      if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not stage server-local-data archive; DB restore is complete, file volume untouched.' }
      else {
        & docker exec $serverContainer sh -c 'mkdir -p /app/packages/twenty-server/.local-storage && tar -xzf /tmp/mahabbat-restore-local-data.tar.gz -C /app/packages/twenty-server/.local-storage && rm -f /tmp/mahabbat-restore-local-data.tar.gz'
        if ($LASTEXITCODE -ne 0) { Write-Warning 'server-local-data extract failed; DB restore is complete, file volume may be stale.' }
        else { Write-Host 'server-local-data restored from the same backup.' }
      }
    } else { Write-Warning 'server container is not running; file volume left untouched.' }
  } else { Write-Host 'No server-local-data archive in this backup; file volume left untouched.' }
  Invoke-MahabbatCompose @('start', 'server', 'worker', 'pos-gateway')
  Write-Host 'Restore completed. Run mahabbat-start.ps1 and verify runtime parity/reconciliation.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
} finally {
  if (-not [string]::IsNullOrEmpty($tempDump)) { Remove-MahabbatFileSecure -Path $tempDump }
  if ($null -ne $pwBytes) { Clear-MahabbatByteArray -Bytes $pwBytes }
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
}
