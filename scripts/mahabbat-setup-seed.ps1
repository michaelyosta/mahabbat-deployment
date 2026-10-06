[CmdletBinding(DefaultParameterSetName = 'EnvFile')]
param(
  [Parameter(ParameterSetName = 'EnvFile')][string]$EnvFile = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$PinW = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$PinA = ''
)

# GUI step: venue seed (halls, tables, menu, payments, staff) from wizard PINs.
# Called by the installer wizard; PINs stay in the local .env only.
# Secrets arrive ONLY via scoped env-file (never argv: visible in ps).
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')

function Set-SeedEnvValue {
  param([string]$Root, [string]$Name, [string]$Value)
  $envPath = Join-Path $Root '.env'
  $lines = @()
  if (Test-Path -LiteralPath $envPath -PathType Leaf) { $lines = @(Get-Content -LiteralPath $envPath -Encoding UTF8) }
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $updated = $false
  $result = foreach ($line in $lines) {
    if (-not $updated -and $line -match $pattern) { "$Name=$Value"; $updated = $true }
    else { $line }
  }
  if (-not $updated) { $result += "$Name=$Value" }
  [IO.File]::WriteAllText($envPath, (($result -join "`r`n") + "`r`n"))
}

try {
  $root = Get-MahabbatRoot
  $fromFile = @{}
  if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { throw 'Файл secrets не найден.' }
    foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { $fromFile[$matches[1]] = $matches[2].Trim() }
    }
    Remove-MahabbatFileSecure -Path $EnvFile
  }
  $pinW = if ($fromFile.ContainsKey('MAHABBAT_SETUP_PIN_W')) { [string]$fromFile['MAHABBAT_SETUP_PIN_W'] } else { $PinW }
  $pinA = if ($fromFile.ContainsKey('MAHABBAT_SETUP_PIN_A')) { [string]$fromFile['MAHABBAT_SETUP_PIN_A'] } else { $PinA }
  if ($PSCmdlet.ParameterSetName -eq 'Legacy') {
    Write-Warning 'Параметры -PinW/-PinA устарели: PIN в argv виден в ps. Используйте -EnvFile.'
  }
  foreach ($candidate in @($pinW, $pinA)) {
    if ($candidate -notmatch '^\d{4,8}$') { throw 'PIN-коды — 4–8 цифр.' }
  }
  if ($pinW -eq $pinA) { throw 'PIN-коды должны отличаться.' }
  Set-SeedEnvValue -Root $root -Name 'MAHABBAT_POS_SEED_WAITER_PIN' -Value $pinW
  Set-SeedEnvValue -Root $root -Name 'MAHABBAT_POS_SEED_ADMIN_PIN' -Value $pinA
  Set-MahabbatEnvAcl
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { throw 'Код приложения отсутствует. Повторите подготовку.' }
  $seedPath = Join-Path $inner.Path 'scripts/seed-venue.mjs'
  if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) { throw 'Стартовые данные отсутствуют в приложении.' }

  $envMap = Get-MahabbatEnvMap
  $apiKey = Get-MahabbatEnvValue -Map $envMap -Name 'MAHABBAT_API_KEY'
  if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Ключ отсутствует. Повторите шаг владельца.' }

  Push-Location $inner.Path
  try {
    $env:MAHABBAT_API_URL = 'http://localhost:3000'
    $env:MAHABBAT_API_KEY = $apiKey
    $env:MAHABBAT_POS_SEED_WAITER_PIN = $pinW
    $env:MAHABBAT_POS_SEED_ADMIN_PIN = $pinA
    $pinW = $null; $pinA = $null
    $seedNode = Join-Path $root 'installer/app/runtime/node.exe'
    if (-not (Test-Path -LiteralPath $seedNode -PathType Leaf)) { $seedNode = (Get-Command node -ErrorAction Stop).Source }
    & $seedNode scripts/seed-venue.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Venue seed failed.' }
  } finally {
    Remove-Item -LiteralPath 'Env:MAHABBAT_API_URL' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:MAHABBAT_API_KEY' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:MAHABBAT_POS_SEED_WAITER_PIN' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:MAHABBAT_POS_SEED_ADMIN_PIN' -ErrorAction SilentlyContinue
    Pop-Location
  }
  Write-Host 'Залы, столы, меню и сотрудники созданы.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
