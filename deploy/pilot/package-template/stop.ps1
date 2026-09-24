[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  Stop-PilotPrintGateway
  if (Test-Path -LiteralPath (Join-Path (Get-PilotRoot) '.env') -PathType Leaf) {
    Invoke-PilotCompose @('stop')
  }
  Write-Host 'Mahabbat остановлен. База данных и остальные данные сохранены.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
