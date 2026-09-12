[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
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
  $backupDir = Join-Path (Join-Path (Get-MahabbatRoot) 'backups') $timestamp
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

  $outerHead = ((& git -C (Get-MahabbatRoot) rev-parse HEAD 2>$null) -join '').Trim()
  if ([string]::IsNullOrWhiteSpace($outerHead)) { $outerHead = '<uncommitted>' }
  $manifest = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    innerSha = $inner.Actual
    outerSha = $outerHead
    database = [ordered]@{ container = 'db'; name = $dbName; user = $dbUser }
    dump = 'database.dump'
    validation = 'pg_restore --list passed inside the PostgreSQL 16 container'
    restoreNotes = 'Stop server, worker, and POS first. Restore only as an explicit operator action using mahabbat-restore.ps1.'
  }
  [IO.File]::WriteAllText((Join-Path $backupDir 'backup-manifest.json'), ($manifest | ConvertTo-Json -Depth 5))
  Write-Host "Backup created: $backupDir"
  Write-Host 'Manifest and dump validated; credentials are not included.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
