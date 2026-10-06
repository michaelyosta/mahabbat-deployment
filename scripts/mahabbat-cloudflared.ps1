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
    # cloudflared service install читает токен из файла, а не из argv:
    # копируем в канонический token-файл туннеля и ставим ACL.
    $dest = Get-MahabbatCloudflaredTokenFile
    $destDir = Split-Path -Parent $dest
    [IO.Directory]::CreateDirectory($destDir) | Out-Null
    Copy-Item -LiteralPath $TokenFile -Destination $dest -Force
    Set-MahabbatPrivateFileAcl -Path $dest
    $token = (Get-Content -Raw -LiteralPath $dest).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Tunnel token file is empty.' }
    & $state.Executable service install --token-file $dest *> $null
    $code = $LASTEXITCODE
    Remove-Variable token -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw 'cloudflared service installation failed.' }
    Write-Host 'cloudflared service installed. Token was not printed or stored by this script.'
    exit 0
  }
  if ($Action -eq 'start') {
    if ($state.ServicePresent) { Start-Service -Name $state.ServiceName } else { Start-MahabbatCloudflaredManagedProcess }
    Write-Host 'cloudflared connector start complete.'
  }
  if ($Action -eq 'stop') {
    if (-not (Stop-MahabbatCloudflaredService)) { throw 'cloudflared connector stop failed.' }
    Write-Host 'cloudflared connector stop complete.'
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
