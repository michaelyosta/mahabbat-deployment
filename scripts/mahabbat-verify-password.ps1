[CmdletBinding(DefaultParameterSetName = 'EnvFile')]
param(
  [Parameter(ParameterSetName = 'EnvFile')][string]$EnvFile = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$BackupPath = ''
)

# «Проверить пароль» (HMAC-only, без restore и без расшифровки).
# Backup v2: проверяет ОБА payload одним паролем — database.dump.enc И
# server-local-data.tar.gz.enc (тот же AES-256-CBC+HMAC-SHA256/PBKDF2 200k).
# Ночные DPAPI-копии проверяются ключом текущего пользователя Windows.
# Legacy v1 (шифрованная БД + открытый tar, без backupVersion) читается
# обратно совместимо: пароль проверяется по БД, файлы помечаются legacy.
# Секреты — только через scoped env-file (setup-api), либо интерактивный ввод.
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-validate.ps1')

try {
  $dir = $BackupPath
  $secret = $null
  if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { throw 'Файл secrets не найден.' }
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
        if ($matches[1] -eq 'MAHABBAT_VERIFY_PASSWORD') { $secret = $matches[2].Trim() }
        if ($matches[1] -eq 'MAHABBAT_VERIFY_DIR') { $dir = $matches[2].Trim() }
      }
    }
    Remove-MahabbatFileSecure -Path $EnvFile
  }
  if ([string]::IsNullOrWhiteSpace($dir)) { throw 'Укажите папку копии (-BackupPath).' }
  $backupDir = [IO.Path]::GetFullPath($dir)
  $preflight = Test-MahabbatBackupManifest -BackupDir $backupDir
  if (-not $preflight.Ok) { throw $preflight.Reason }
  $manifest = $preflight.Manifest
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  $encPath = Join-Path $backupDir 'database.dump.enc'
  if (-not (Test-Path -LiteralPath $encPath -PathType Leaf)) { throw 'В папке нет database.dump.enc (копия не зашифрована).' }
  # Files payload discovery (StrictMode-safe: property presence first).
  $filesEncPath = Join-Path $backupDir 'server-local-data.tar.gz.enc'
  $filesPlainPath = Join-Path $backupDir 'server-local-data.tar.gz'
  $filesField = ''
  try { if ($null -ne $manifest.files) { $filesField = [string]$manifest.files } } catch { $filesField = '' }
  $wantFilesCheck = ((Test-Path -LiteralPath $filesEncPath -PathType Leaf) -or ($filesField -match 'server-local-data\.tar\.gz\.enc'))
  if ($wantFilesCheck -and (-not (Test-Path -LiteralPath $filesEncPath -PathType Leaf))) { throw 'manifest ссылается на server-local-data.tar.gz.enc, но файла нет — проверка файлов невозможна.' }
  $filesDigestExpect = ''
  try {
    if (($manifest.PSObject.Properties.Name -contains 'filesSha256') -and ($null -ne $manifest.filesSha256)) { $filesDigestExpect = ([string]$manifest.filesSha256).Trim() }
  } catch { $filesDigestExpect = '' }
  $legacyOpenTar = ((-not $wantFilesCheck) -and (Test-Path -LiteralPath $filesPlainPath -PathType Leaf))
  # Nightly DPAPI copies: the same Windows-user key protects BOTH payloads.
  $keySource = ''
  try {
    if (($manifest.PSObject.Properties.Name -contains 'encryption') -and ($null -ne $manifest.encryption) -and ($manifest.encryption.PSObject.Properties.Name -contains 'keySource')) {
      $keySource = [string]$manifest.encryption.keySource
    }
  } catch { $keySource = '' }
  if ($keySource -like 'DPAPI*') {
    $keyBytes = Get-MahabbatNightlyBackupKeyBytes
    $pwBytes = $null
    try {
      $pwBytes = $keyBytes
      $keyBytes = $null
      $okDb = Test-MahabbatBackupPassword -EncPath $encPath -ManifestPath $manifestPath -PasswordBytes $pwBytes
      if (-not $okDb) { throw 'Ночной ключ не подошёл или файл повреждён.' }
      if ($wantFilesCheck) {
        $okFiles = Test-MahabbatBackupPayloadPassword -EncPath $filesEncPath -PasswordBytes $pwBytes -ExpectedSha256 $filesDigestExpect
        if (-not $okFiles) { throw 'Ночной ключ не подошёл или архив файлов повреждён.' }
      }
    } finally {
      if ($null -ne $pwBytes) { Clear-MahabbatByteArray -Bytes $pwBytes }
    }
    if ($wantFilesCheck) { Write-Host 'Ключ верный: HMAC и SHA256-манифест сошлись (БД+файлы, ночной DPAPI-ключ). Восстановление не выполнялось.' }
    else { Write-Host 'Ключ верный: HMAC и SHA256-манифест сошлись (БД, ночной DPAPI-ключ; файловый архив отсутствует). Восстановление не выполнялось.' }
    return
  }
  if ($null -eq $secret) {
    $envPw = [Environment]::GetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', 'Process')
    [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
    if (-not [string]::IsNullOrEmpty($envPw)) { $secret = $envPw }
  }
  if ($null -eq $secret) {
    $secure = Read-Host 'Пароль копии' -AsSecureString
    try { $secret = Convert-MahabbatSecureStringToString -Secure $secure }
    finally { $secure.Dispose() }
  }
  if ([string]::IsNullOrEmpty($secret) -or $secret.Length -lt 10 -or $secret.Length -gt 128) { throw 'Неверный пароль или повреждённый файл.' }
  $pwBytes = [Text.Encoding]::UTF8.GetBytes($secret)
  $secret = $null
  try {
    $okDb = Test-MahabbatBackupPassword -EncPath $encPath -ManifestPath $manifestPath -PasswordBytes $pwBytes
    if (-not $okDb) { throw 'Неверный пароль или повреждённый файл.' }
    if ($wantFilesCheck) {
      $okFiles = Test-MahabbatBackupPayloadPassword -EncPath $filesEncPath -PasswordBytes $pwBytes -ExpectedSha256 $filesDigestExpect
      if (-not $okFiles) { throw 'Неверный пароль или повреждённый архив файлов.' }
    }
  } finally {
    Clear-MahabbatByteArray -Bytes $pwBytes
  }
  if ($wantFilesCheck) { Write-Host 'Пароль верный: HMAC и SHA256-манифест сошлись (БД+файлы). Восстановление не выполнялось.' }
  elseif ($legacyOpenTar) { Write-Host 'Пароль верный: HMAC и SHA256-манифест сошлись (БД; файлы открытым tar — legacy v1, пароль проверен только по БД). Восстановление не выполнялось.' }
  else { Write-Host 'Пароль верный: HMAC и SHA256-манифест сошлись (БД; файловый архив отсутствует). Восстановление не выполнялось.' }
} catch {
  Write-Error $_.Exception.Message
  exit 1
} finally {
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
}
