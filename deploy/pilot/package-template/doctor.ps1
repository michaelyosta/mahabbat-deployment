[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

$issues = [System.Collections.Generic.List[string]]::new()
try { Assert-PilotMachineBinding | Out-Null; Write-Host 'Привязка к компьютеру: PASS' }
catch { $issues.Add($_.Exception.Message); Write-Host 'Привязка к компьютеру: FAIL' }

try {
  Assert-PilotDocker
  Write-Host 'Docker Engine и Compose: PASS'
  $root = Get-PilotRoot
  $envMap = Get-PilotEnvMap
  foreach ($portKey in @('CRM_PORT', 'POS_PORT', 'LICENSE_STATUS_PORT', 'PRINT_GATEWAY_PORT')) {
    $port = [int](Get-PilotEnvValue $envMap $portKey '0')
    if ($port -lt 1 -or $port -gt 65535) { $issues.Add("Некорректный порт $portKey."); Write-Host "$portKey`: FAIL" }
  }
  Invoke-PilotCompose @('config', '--quiet')
  Write-Host 'Конфигурация сервисов: PASS'
} catch { $issues.Add($_.Exception.Message); Write-Host "Docker/configuration: FAIL ($($_.Exception.Message))" }

$urls = $null
try { $urls = Get-PilotUrlMap } catch { }
if ($urls) {
  foreach ($check in @(
      @{ Name = 'CRM'; Url = $urls.Crm + '/healthz' },
      @{ Name = 'POS'; Url = $urls.Pos + '/health' },
      @{ Name = 'Лицензионный статус'; Url = $urls.LicenseStatus },
      @{ Name = 'Шлюз печати'; Url = $urls.PrintHealth }
    )) {
    $pass = Test-PilotUrl $check.Url
    Write-Host ("{0}: {1}" -f $check.Name, $(if ($pass) { 'PASS' } else { 'OFFLINE' }))
  }
  $license = Get-PilotLicenseStatus
  Write-Host "Лицензия: $($license.status)"
  if ($license.status -eq 'CLOCK_ROLLBACK') { $issues.Add('Обнаружен перевод системного времени назад.') }
}
if ($issues.Count -gt 0) { Write-Host "Найдено замечаний: $($issues.Count)"; exit 1 }
Write-Host 'DOCTOR=PASS'
