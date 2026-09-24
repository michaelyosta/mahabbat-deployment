[CmdletBinding()]
param([string]$OutputPath)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $installation = Assert-PilotMachineBinding
  $source = Join-Path (Get-PilotRoot) 'license\activation-request.json'
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Запрос активации отсутствует. Сначала запустите install.ps1.' }
  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputPath = Join-Path $desktop ('Mahabbat-activation-{0}.json' -f $installation.installation_id)
  } else { $OutputPath = [IO.Path]::GetFullPath($OutputPath) }
  Copy-Item -LiteralPath $source -Destination $OutputPath -Force
  Write-Host "Запрос активации создан: $OutputPath"
  Write-Host 'Передайте этот файл сопровождающему для выпуска лицензии. Секретов в запросе нет.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
