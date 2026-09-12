[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BackupPath,
  [switch]$ConfirmRestore
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  $backupDir = [IO.Path]::GetFullPath($BackupPath)
  $manifestPath = Join-Path $backupDir 'backup-manifest.json'
  $dumpPath = Join-Path $backupDir 'database.dump'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
    throw 'Backup must contain backup-manifest.json and database.dump.'
  }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  Write-Host "Backup timestamp: $($manifest.timestamp)"
  Write-Host "Backup inner SHA: $($manifest.innerSha)"
  Write-Host 'This operation will overwrite the live PostgreSQL database after stopping application services.'
  if (-not $ConfirmRestore) {
    Write-Host 'Refusing to restore without explicit -ConfirmRestore.'
    exit 2
  }
  $answer = Read-Host 'Type RESTORE MAHABBAT to continue'
  if ($answer -cne 'RESTORE MAHABBAT') { Write-Host 'Restore cancelled.'; exit 2 }

  Assert-MahabbatDockerEngine
  $dbContainer = Get-MahabbatServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($dbContainer)) { throw 'PostgreSQL container is not running.' }
  $envMap = Get-MahabbatEnvMap
  $dbUser = Get-MahabbatEnvValue $envMap 'PG_DATABASE_USER' 'postgres'
  $dbName = Get-MahabbatEnvValue $envMap 'PG_DATABASE_NAME' 'default'
  Invoke-MahabbatCompose @('stop', 'server', 'worker', 'pos-gateway')
  $containerDump = '/tmp/mahabbat-restore.dump'
  & docker cp $dumpPath "${dbContainer}:$containerDump"
  if ($LASTEXITCODE -ne 0) { throw 'Could not copy dump into PostgreSQL container.' }
  & docker exec $dbContainer pg_restore --clean --if-exists --exit-on-error --no-owner --no-acl -U $dbUser -d $dbName $containerDump
  $restoreExit = $LASTEXITCODE
  & docker exec $dbContainer rm -f $containerDump 2>$null
  if ($restoreExit -ne 0) { throw 'pg_restore failed; application services remain stopped for inspection.' }
  Invoke-MahabbatCompose @('start', 'server', 'worker', 'pos-gateway')
  Write-Host 'Restore completed. Run mahabbat-start.ps1 and verify runtime parity/reconciliation.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
