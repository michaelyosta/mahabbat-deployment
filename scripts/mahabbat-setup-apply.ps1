[CmdletBinding()]
param()

# GUI step: metadata plan + apply without the interactive DA prompt.
# Called by the installer wizard after the owner step.
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action plan
  if ($LASTEXITCODE -ne 0) { throw 'Проверка данных не удалась.' }
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action apply
  if ($LASTEXITCODE -ne 0) { throw 'Применение данных не удалось.' }
  Write-Host 'Данные приложения применены.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
