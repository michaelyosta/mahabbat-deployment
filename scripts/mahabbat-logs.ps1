[CmdletBinding()]
param(
  [ValidateSet('all', 'pos', 'twenty', 'server', 'worker', 'db', 'redis')]
  [string]$Service = 'all',
  [switch]$Follow,
  [int]$Tail = 200
)

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  Assert-MahabbatDockerEngine
  $target = switch ($Service) {
    'pos' { 'pos-gateway' }
    'twenty' { 'server' }
    default { $Service }
  }
  $args = @('logs', '--tail', [string]$Tail)
  if ($Follow) { $args += '--follow' }
  if ($target -ne 'all') { $args += $target }
  Invoke-MahabbatCompose $args
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
