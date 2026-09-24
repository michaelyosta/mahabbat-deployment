[CmdletBinding()]
param([switch]$NoBrowser)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $installation = Assert-PilotMachineBinding
  Start-PilotDockerDesktop
  Invoke-PilotCompose @('config', '--quiet')
  Invoke-PilotCompose @('up', '-d')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw 'Сервисы не готовы. Запустите status.ps1 и doctor.ps1; данные не удалялись.' }
  Start-PilotPrintGateway
  $urls = Get-PilotUrlMap
  $license = Get-PilotLicenseStatus
  Write-Host "MAHABBAT $((Get-Content (Join-Path (Get-PilotRoot) 'VERSION') -Raw).Trim()) · installation $($installation.installation_id)"
  if ($license.active) { Write-Host "Лицензия активна до $($license.expiresAt)." }
  else { Write-Host 'Лицензия не активна: система работает в ограниченном режиме.' }
  Write-Host "CRM $($urls.Crm)"
  Write-Host "POS $($urls.Pos)"
  Write-Host 'READY'
  if (-not $NoBrowser) { Start-Process $urls.Crm }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
