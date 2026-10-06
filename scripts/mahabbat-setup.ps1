[CmdletBinding()]
param(
  [switch]$SkipPrerequisites,
  [switch]$SkipSeed,
  [int]$TimeoutSeconds = 600
)

<#
.SYNOPSIS
  Single entrypoint for a fresh restaurant PC: prerequisites -> bootstrap ->
  start -> guided first-run (workspace, API key, plan/apply, parity, venue seed).

  Run from the deployment repository root in PowerShell:

    powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-setup.ps1

  The wizard never commits secrets, never deletes data, and stops at the first
  manual step (Twenty signup + API-key paste) with Russian guidance.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')

function Write-MahabbatStep {
  param([string]$Text)
  Write-Host ''
  Write-Host "=== $Text ==="
}

function Read-MahabbatSecretOnce {
  param([Parameter(Mandatory = $true)][string]$Prompt)
  $secure = Read-Host -Prompt $Prompt -AsSecureString
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  Remove-Variable secure -ErrorAction SilentlyContinue
  return $plain.Trim()
}

function Set-MahabbatEnvValue {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )
  $envPath = Join-Path $Root '.env'
  $lines = @()
  if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    $lines = @(Get-Content -LiteralPath $envPath)
  }
  $pattern = "^\s*$([regex]::Escape($Name))\s*="
  $updated = $false
  $result = foreach ($line in $lines) {
    if (-not $updated -and $line -match $pattern) { "$Name=$Value"; $updated = $true }
    else { $line }
  }
  if (-not $updated) { $result += "$Name=$Value" }
  [IO.File]::WriteAllText($envPath, (($result -join "`r`n") + "`r`n"))
}

function Test-MahabbatSeedRunnable {
  $inner = Get-MahabbatInnerState
  if (-not $inner.Present) { return $false }
  return (Test-Path -LiteralPath (Join-Path $inner.Path 'scripts/seed-pos.mjs') -PathType Leaf)
}

try {
  $root = Get-MahabbatRoot
  $venue = Get-MahabbatVenueName
  Write-Host "MAHABBAT SETUP ($venue)"

  if (-not $SkipPrerequisites) {
    Write-MahabbatStep 'Шаг 1/6. Проверка требований'
    & (Join-Path $PSScriptRoot 'mahabbat-doctor.ps1')
    if ($LASTEXITCODE -ne 0) {
      Write-Warning 'Proverka pokazala zamechaniya vyshe. Ustranite krasnye punkty (Docker Desktop, Node 24, spuler) i zapustite ustanovku snova.'
      exit 1
    }
  }

  Write-MahabbatStep 'Шаг 2/6. Подготовка (.env + код приложения)'
  & (Join-Path $PSScriptRoot 'mahabbat-bootstrap.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Bootstrap failed. See the message above.' }

  Write-MahabbatStep 'Шаг 3/6. Запуск (база, сервер, касса, печать)'
  & (Join-Path $PSScriptRoot 'mahabbat-start.ps1') -TimeoutSeconds $TimeoutSeconds
  if ($LASTEXITCODE -ne 0) { throw 'Start failed. Run .\scripts\mahabbat-logs.ps1 for details.' }

  $envMap = Get-MahabbatEnvMap
  $apiKey = Get-MahabbatEnvValue -Map $envMap -Name 'TWENTY_API_KEY'
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-MahabbatStep 'Шаг 4/6. Владелец и ключ (без браузера)'
    Write-Host 'Придумайте почту и пароль владельца (пароль 8-50 символов). Они останутся только в локальном .env и базе.'
    $ownerEmail = (Read-Host -Prompt 'Почта владельца').Trim().ToLowerInvariant()
    $ownerPassword = Read-MahabbatSecretOnce -Prompt 'Пароль владельца'
    if ([string]::IsNullOrWhiteSpace($ownerEmail) -or -not $ownerEmail.Contains('@')) { throw 'Нужна корректная почта владельца.' }
    if ($ownerPassword.Length -lt 8 -or $ownerPassword.Length -gt 50) { throw 'Пароль должен быть 8-50 символов.' }
    Set-MahabbatEnvValue -Root $root -Name 'MAHABBAT_VENUE_EMAIL' -Value $ownerEmail
    $serverContainer = Get-MahabbatServiceContainerId 'server'
    if ([string]::IsNullOrWhiteSpace($serverContainer)) { throw 'Twenty server container is not running.' }
    $venueName = Get-MahabbatVenueName
    # Пароль — только через env дочернего docker exec (никогда в argv).
    $previousPw = [Environment]::GetEnvironmentVariable('MAHABBAT_VENUE_PASSWORD', 'Process')
    try {
      [Environment]::SetEnvironmentVariable('MAHABBAT_VENUE_PASSWORD', $ownerPassword, 'Process')
      $bootstrapOut = (& docker exec -i -e MAHABBAT_VENUE_EMAIL=$ownerEmail -e MAHABBAT_VENUE_PASSWORD -e MAHABBAT_VENUE_NAME=$venueName -e MAHABBAT_VENUE_LOCALE=ru-RU $serverContainer yarn command:prod workspace:bootstrap:venue 2>&1) -join "`n"
    } finally {
      if ($null -eq $previousPw) { [Environment]::SetEnvironmentVariable('MAHABBAT_VENUE_PASSWORD', $null, 'Process') }
      else { [Environment]::SetEnvironmentVariable('MAHABBAT_VENUE_PASSWORD', $previousPw, 'Process') }
    }
    Remove-Variable ownerPassword -ErrorAction SilentlyContinue
    $matchKey = [regex]::Match($bootstrapOut, 'MAHABBAT_API_KEY=([A-Za-z0-9\-_\.]+)')
    if (-not $matchKey.Success) { Write-Host $bootstrapOut; throw 'Не удалось создать владельца автоматически.' }
    Set-MahabbatEnvValue -Root $root -Name 'TWENTY_API_KEY' -Value $matchKey.Groups[1].Value
    Set-MahabbatEnvValue -Root $root -Name 'MAHABBAT_API_KEY' -Value $matchKey.Groups[1].Value
    Set-MahabbatEnvAcl
    Remove-Variable bootstrapOut -ErrorAction SilentlyContinue
  } else {
    Write-MahabbatStep 'Шаг 4/6. Ключ уже есть, пропускаем создание владельца'
  }

  Write-MahabbatStep 'Шаг 5/6. Метаданные приложения (plan, затем apply)'
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action plan
  if ($LASTEXITCODE -ne 0) { throw 'Metadata plan failed.' }
  $answer = (Read-Host -Prompt 'Plan vyshe vyglyadit razumno? Vvedite DA dlya apply').Trim()
  if ($answer -notin @('DA', 'Da', 'da', 'YES', 'yes', 'Y', 'y')) {
    Write-Host 'Ostanovleno pered apply. Zapustite ustanovku snova posle proverki plana.'
    exit 2
  }
  & (Join-Path $PSScriptRoot 'mahabbat-metadata.ps1') -Action apply
  if ($LASTEXITCODE -ne 0) { throw 'Metadata apply failed.' }

  if (-not $SkipSeed) {
    Write-MahabbatStep 'Шаг 6/6. Стартовые данные заведения'
    if (-not (Test-MahabbatSeedRunnable)) {
      throw 'Inner seed scripts are missing; run bootstrap first.'
    }
    $envMap = Get-MahabbatEnvMap
    $waiterPin = Get-MahabbatEnvValue -Map $envMap -Name 'MAHABBAT_POS_SEED_WAITER_PIN'
    $adminPin = Get-MahabbatEnvValue -Map $envMap -Name 'MAHABBAT_POS_SEED_ADMIN_PIN'
    if ([string]::IsNullOrWhiteSpace($waiterPin) -or [string]::IsNullOrWhiteSpace($adminPin)) {
      Write-Host 'Pridumaite dva PIN-koda kassy (4-8 tsifr): ofitsiant i administrator. Oni ostanutsya tolko v lokalnom .env.'
      $freshWaiter = Read-MahabbatSecretOnce -Prompt 'PIN ofitsianta (WAITER)'
      $freshAdmin = Read-MahabbatSecretOnce -Prompt 'PIN administratora (ADMIN)'
      foreach ($candidate in @($freshWaiter, $freshAdmin)) {
        if ($candidate -notmatch '^\d{4,8}$') { throw 'PIN must contain 4 to 8 digits.' }
      }
      Set-MahabbatEnvValue -Root $root -Name 'MAHABBAT_POS_SEED_WAITER_PIN' -Value $freshWaiter
      Set-MahabbatEnvValue -Root $root -Name 'MAHABBAT_POS_SEED_ADMIN_PIN' -Value $freshAdmin
      Set-MahabbatEnvAcl
      Remove-Variable freshWaiter, freshAdmin -ErrorAction SilentlyContinue
      Write-Host 'PIN-kody zapisany v lokalnyi .env.'
    }
    $inner = Get-MahabbatInnerState
    $seedEnv = @{
      MAHABBAT_API_URL = 'http://localhost:3000'
      MAHABBAT_API_KEY = (Get-MahabbatEnvValue -Map (Get-MahabbatEnvMap) -Name 'MAHABBAT_API_KEY')
    }
    $seedPins = @{
      MAHABBAT_POS_SEED_WAITER_PIN = (Get-MahabbatEnvValue -Map (Get-MahabbatEnvMap) -Name 'MAHABBAT_POS_SEED_WAITER_PIN')
      MAHABBAT_POS_SEED_ADMIN_PIN = (Get-MahabbatEnvValue -Map (Get-MahabbatEnvMap) -Name 'MAHABBAT_POS_SEED_ADMIN_PIN')
    }
    Write-Host 'Zapuskaem venue seed (zony, stoly, menyu, sposoby oplaty, personal) bez acceptance- i demo-musora...'
    Push-Location $inner.Path
    try {
      foreach ($entry in $seedEnv.GetEnumerator()) { Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value }
      foreach ($entry in $seedPins.GetEnumerator()) { Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value }
      & node scripts/seed-venue.mjs
      if ($LASTEXITCODE -ne 0) { throw 'Venue seed failed.' }
    } finally {
      foreach ($entry in $seedEnv.GetEnumerator()) { Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue }
      foreach ($entry in $seedPins.GetEnumerator()) { Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue }
      Pop-Location
    }
  } else {
    Write-Host 'Seed propuschen po flagu -SkipSeed.'
  }

  Write-MahabbatStep 'Готово'
  Write-Host 'CRM: http://localhost:3000/'
  Write-Host 'POS: http://localhost:3100/'
  Write-Host 'Dalshe: russkaya lokalizatsiya uzhe primenena cherez metadata apply; printer nastraivaetsya v Mahabbat -> Pechat.'
  & (Join-Path $PSScriptRoot 'mahabbat-status.ps1')
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
