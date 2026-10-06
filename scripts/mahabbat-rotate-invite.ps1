[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$DryRun
)

# Ротация персональной invite-ссылки: новый inviteHash вместо старого, одной операцией.
# Старая ссылка http://localhost:3000/invite/<старый-хэш> умирает сразу после записи.
# Вручную — так:
#   powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-rotate-invite.ps1
# Проверка без записи в БД:
#   .\scripts\mahabbat-rotate-invite.ps1 -DryRun
#   .\scripts\mahabbat-rotate-invite.ps1 -WhatIf
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  if ($DryRun) { $WhatIfPreference = $true }
  Assert-MahabbatDockerEngine
  $envMap = Get-MahabbatEnvMap
  $dbUser = (Get-MahabbatEnvValue $envMap 'PG_DATABASE_USER' 'postgres').Trim()
  $dbName = (Get-MahabbatEnvValue $envMap 'PG_DATABASE_NAME' 'default').Trim()
  if ([string]::IsNullOrWhiteSpace($dbUser)) { $dbUser = 'postgres' }
  if ([string]::IsNullOrWhiteSpace($dbName)) { $dbName = 'default' }
  $dbContainer = Get-MahabbatServiceContainerId 'db'
  if ([string]::IsNullOrWhiteSpace($dbContainer)) { throw 'База данных не запущена. Запустите Mahabbat (mahabbat-start.ps1) и повторите.' }
  $dbState = Get-MahabbatContainerState $dbContainer
  if ($dbState.State -ne 'running') { throw "Контейнер PostgreSQL не запущен (state: $($dbState.State)). Запустите Mahabbat и повторите." }
  if ($dbState.Health -ne 'healthy') { throw "PostgreSQL не готов (health: $($dbState.Health)). Дождитесь готовности и повторите." }
  # SQL идёт через stdin (docker exec -i): ключи -c на Windows теряют кавычки
  # вокруг camelCase-идентификатора "inviteHash", и запрос падает.
  $countOut = (( 'SELECT count(*) FROM "core"."workspace";' | & docker exec -i $dbContainer psql -U $dbUser -d $dbName -v ON_ERROR_STOP=1 -t -A 2>&1) -join "`n").Trim()
  if ($LASTEXITCODE -ne 0) { throw "Не удалось прочитать core.workspace: $countOut" }
  if ($countOut -ne '1') { throw "Ожидалась ровно одна рабочая область в core.workspace, найдено: $countOut. Ротация не выполнена." }
  $newHash = [guid]::NewGuid().ToString()
  $link = "http://localhost:3000/invite/$newHash"
  if ($PSCmdlet.ShouldProcess('core.workspace.inviteHash', 'записать новый inviteHash')) {
    $writeSql = "UPDATE `"core`".`"workspace`" SET `"inviteHash`" = '$newHash' RETURNING `"inviteHash`";"
    $updated = (( $writeSql | & docker exec -i $dbContainer psql -U $dbUser -d $dbName -v ON_ERROR_STOP=1 -t -A 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Запись inviteHash не выполнена: $updated" }
    if ($updated -ne $newHash) { throw 'БД не вернула новый inviteHash. Проверьте core.workspace и повторите.' }
    Write-Host "Новая ссылка для приглашения: $link"
    Write-Host 'ВНИМАНИЕ: старая invite-ссылка больше недействительна — разошлите новую обычным каналом.'
  } else {
    Write-Host "[dry-run] БД не изменена. Был бы записан новый inviteHash, ссылка: $link"
    Write-Host '[dry-run] Старая invite-ссылка осталась бы действовать до реальной ротации.'
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
