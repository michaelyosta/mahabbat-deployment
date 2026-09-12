[CmdletBinding()]
param(
  [ValidateSet('status', 'install', 'start', 'stop')]
  [string]$Action = 'status',
  [string]$TokenFile = ''
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  if ($Action -eq 'status') {
    $state = Get-MahabbatCloudflaredState
    Write-Host "Installed: $($state.Installed)"
    Write-Host "Service: $($state.ServicePresent)"
    Write-Host "Status: $($state.Status)"
    exit 0
  }
  $state = Get-MahabbatCloudflaredState
  if (-not $state.Installed) { throw 'cloudflared is not installed. Put the official executable in .cloudflared or add it to PATH.' }
  if ($Action -eq 'install') {
    if ([string]::IsNullOrWhiteSpace($TokenFile)) { throw 'Provide -TokenFile pointing to a local ignored file containing the existing tunnel token.' }
    if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) { throw 'Tunnel token file does not exist.' }
    $token = (Get-Content -Raw -LiteralPath $TokenFile).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Tunnel token file is empty.' }
    & $state.Executable service install $token *> $null
    if ($LASTEXITCODE -ne 0) { throw 'cloudflared service installation failed.' }
    Remove-Variable token -ErrorAction SilentlyContinue
    Write-Host 'cloudflared service installed. Token was not printed or stored by this script.'
    exit 0
  }
  if (-not $state.ServicePresent) { throw 'cloudflared Windows service is not installed.' }
  if ($Action -eq 'start') { Start-Service -Name $state.ServiceName }
  if ($Action -eq 'stop') { Stop-Service -Name $state.ServiceName }
  Write-Host "cloudflared service action complete: $Action"
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
