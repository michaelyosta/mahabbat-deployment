[CmdletBinding(DefaultParameterSetName = 'EnvFile')]
param(
  [Parameter(ParameterSetName = 'EnvFile')][string]$EnvFile = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$BackupPath = ''
)

# «Проверить пароль» (HMAC-only, без restore и без расшифровки дампа).
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
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  $encPath = Join-Path $backupDir 'database.dump.enc'
  if (-not (Test-Path -LiteralPath $encPath -PathType Leaf)) { throw 'В папке нет database.dump.enc (копия не зашифрована).' }
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
    $ok = Test-MahabbatBackupPassword -EncPath $encPath -ManifestPath $manifestPath -PasswordBytes $pwBytes
  } finally {
    Clear-MahabbatByteArray -Bytes $pwBytes
  }
  if (-not $ok) { throw 'Неверный пароль или повреждённый файл.' }
  Write-Host 'Пароль верный: HMAC и SHA256-манифест сошлись. Восстановление не выполнялось.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
} finally {
  [Environment]::SetEnvironmentVariable('MAHABBAT_BACKUP_PASSWORD', $null, 'Process')
}
