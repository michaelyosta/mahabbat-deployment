[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LicensePath)

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $installation = Assert-PilotMachineBinding
  $source = [IO.Path]::GetFullPath($LicensePath)
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Файл лицензии не найден.' }
  $document = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
  if ($document.payload.product -ne 'Mahabbat' -or
      $document.payload.installation_id -cne $installation.installation_id -or
      $document.payload.machine_fingerprint -cne $installation.machine_fingerprint) {
    throw 'Лицензия выпущена для другой установки или компьютера. Текущий файл не изменён.'
  }

  Start-PilotDockerDesktop
  Invoke-PilotCompose @('up', '-d')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw 'Runtime не готов. Текущая лицензия не изменена.' }
  $root = Get-PilotRoot
  $destination = Join-Path $root 'license\license.json'
  $temporary = "$destination.new"
  $previous = "$destination.previous"
  Copy-Item -LiteralPath $source -Destination $temporary -Force
  if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force }
  if (Test-Path -LiteralPath $destination) { Move-Item -LiteralPath $destination -Destination $previous }
  Move-Item -LiteralPath $temporary -Destination $destination
  $license = Get-PilotLicenseStatus
  if (-not $license.active) {
    Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $previous) { Move-Item -LiteralPath $previous -Destination $destination }
    throw "Подпись или параметры лицензии не прошли проверку ($($license.status)); предыдущая лицензия сохранена."
  }
  if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force }
  Write-Host "Лицензия активирована до $($license.expiresAt)."
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
