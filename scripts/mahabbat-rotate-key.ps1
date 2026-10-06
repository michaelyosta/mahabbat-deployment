[CmdletBinding()]
param()

# Ротация API-ключа заведения: новый ключ вместо старого, одной операцией.
# Старый ключ отзывается только после того, как новый выпущен и проверен.
# Вызывается из мастера установки и значка возле часов; вручную — так:
#   powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-rotate-key.ps1
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

function Set-RotateEnvValue {
  param([string]$Root, [string]$Name, [string]$Value)
  $envPath = Join-Path $Root '.env'
  $lines = @()
  if (Test-Path -LiteralPath $envPath -PathType Leaf) { $lines = @(Get-Content -LiteralPath $envPath) }
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $updated = $false
  $result = foreach ($line in $lines) {
    if (-not $updated -and $line -match $pattern) { "$Name=$Value"; $updated = $true }
    else { $line }
  }
  if (-not $updated) { $result += "$Name=$Value" }
  [IO.File]::WriteAllText($envPath, (($result -join "`r`n") + "`r`n"))
}

function Get-WorkspaceIdFromKey {
  param([string]$Token)
  $parts = $Token.Split('.')
  if ($parts.Count -ne 3) { throw 'Старый ключ повреждён.' }
  $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
  while (($b64.Length % 4) -ne 0) { $b64 += '=' }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
  return (($json | ConvertFrom-Json).sub)
}

try {
  Assert-MahabbatDockerEngine
  $root = Get-MahabbatRoot
  $envMap = Get-MahabbatEnvMap
  $oldKey = (Get-MahabbatEnvValue $envMap 'TWENTY_API_KEY').Trim()
  if ([string]::IsNullOrWhiteSpace($oldKey)) { throw 'Ключ отсутствует. Сначала завершите установку.' }
  $workspaceId = Get-WorkspaceIdFromKey $oldKey
  if ($workspaceId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Не удалось определить заведение из ключа.' }
  $serverContainer = Get-MahabbatServiceContainerId 'server'
  if ([string]::IsNullOrWhiteSpace($serverContainer)) { throw 'Сервер не запущен. Запустите Mahabbat и повторите.' }
  $stamp = Get-Date -Format 'yyyy-MM-dd'
  $rotateOut = (& docker exec -i $serverContainer yarn command:prod workspace:rotate-api-key --workspace-id $workspaceId --name "Mahabbat venue key $stamp" --allow-production 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) { Write-Host $rotateOut; throw "Ротация не выполнена (код $LASTEXITCODE). Старый ключ продолжает действовать." }
  $matchKey = [regex]::Match($rotateOut, 'MAHABBAT_API_KEY=([A-Za-z0-9\-_\.]+)')
  if (-not $matchKey.Success) { Write-Host $rotateOut; throw 'Сервер не вернул новый ключ. Старый ключ продолжает действовать, перезапуск не выполнен.' }
  $newKey = $matchKey.Groups[1].Value
  # Сначала пишем оба имени ключа в .env, затем проверяем новым токеном —
  # рестарт только после успешной проверки.
  Set-RotateEnvValue -Root $root -Name 'TWENTY_API_KEY' -Value $newKey
  Set-RotateEnvValue -Root $root -Name 'MAHABBAT_API_KEY' -Value $newKey
  $envMap = Get-MahabbatEnvMap
  $serverUrl = (Get-MahabbatEnvValue $envMap 'SERVER_URL' 'http://127.0.0.1:3000').TrimEnd('/')
  if ([string]::IsNullOrWhiteSpace($serverUrl)) { $serverUrl = 'http://127.0.0.1:3000' }
  try {
    $null = Invoke-RestMethod -UseBasicParsing -Uri "$serverUrl/rest/apiKeys" -Headers @{ Authorization = "Bearer $newKey" } -TimeoutSec 15 -ErrorAction Stop
  } catch {
    throw "Новый ключ записан в .env, но проверка им не прошла: $($_.Exception.Message). Перезапуск не выполнен — проверьте сервер и повторите ротацию."
  }
  $posId = Get-MahabbatServiceContainerId 'pos-gateway'
  # Сброс кэша ключей: workspace apiKeyMap кэшируется, рестарт обязателен.
  Invoke-MahabbatCompose @('up', '-d', '--force-recreate', 'server')
  if (-not [string]::IsNullOrWhiteSpace($posId)) {
    Invoke-MahabbatCompose @('up', '-d', 'pos-gateway')
  }
  Write-Host 'Ключ перевыпущен. Старый ключ отозван, касса переподключена.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
