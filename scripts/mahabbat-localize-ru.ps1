[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

try {
  $root = Get-MahabbatRoot
  $envMap = Get-MahabbatEnvMap
  $apiKey = Get-MahabbatEnvValue -Map $envMap -Name 'TWENTY_API_KEY'
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw 'TWENTY_API_KEY is missing from the local .env.'
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw 'Node.js is required to synchronize the workspace command menu.' }

  $scriptPath = Join-Path $PSScriptRoot 'mahabbat-localize-ru.mjs'
  & $node.Source $scriptPath
  if ($LASTEXITCODE -ne 0) { throw 'Russian command menu synchronization failed.' }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
