[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $path = New-PilotDatabaseBackup
  Write-Host "Путь: $path"
  Write-Host 'В резервной копии есть база и конфигурация этой установки. Пароли в отчёт не выводятся.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
