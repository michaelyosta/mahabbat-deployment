[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

# A fresh PC has no .env, application checkout, metadata or running services.
# Check installation prerequisites here; doctor checks the installed runtime.
$issues = @()
if (Test-MahabbatDockerEngine) { Write-Host 'DOCKER PASS' }
else { $issues += 'Docker Engine is unavailable. Start Docker Desktop.' }

if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host 'GIT PASS' }
else { $issues += 'Git is not installed. Install Git for Windows.' }

$nodePath = Join-Path (Get-MahabbatRoot) 'installer/app/runtime/node.exe'
if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  if ($null -ne $nodeCommand) { $nodePath = $nodeCommand.Source }
}
if (Test-Path -LiteralPath $nodePath -PathType Leaf) {
  $version = ((& $nodePath --version 2>$null) -join '').Trim()
  if ($version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 24) { Write-Host "NODE $version PASS" }
  else { $issues += "Node 24 or newer is required; found '$version'." }
} else { $issues += 'The bundled Node runtime is missing. Reinstall Mahabbat.' }

foreach ($port in @(3000, 3100)) {
  if (Test-MahabbatPortListening $port) {
    $service = if ($port -eq 3000) { 'server' } else { 'pos-gateway' }
    $owned = ((& docker ps --filter "label=com.docker.compose.project=mahabbat" --filter "label=com.docker.compose.service=$service" --format '{{.ID}}' 2>$null) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($owned)) { $issues += "Port $port is already used by another application." }
  } else { Write-Host "PORT $port FREE" }
}

if ($issues.Count -gt 0) {
  foreach ($issue in $issues) { Write-Host "BLOCKED: $issue" }
  exit 1
}
Write-Host 'PREREQUISITES PASS'
exit 0
