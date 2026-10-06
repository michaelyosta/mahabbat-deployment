[CmdletBinding(DefaultParameterSetName = 'EnvFile')]
param(
  [Parameter(ParameterSetName = 'EnvFile')][string]$EnvFile = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$Email = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$Password = '',
  [Parameter(ParameterSetName = 'Legacy')][string]$Venue = ''
)

function Set-MahabbatEnvValueShim {
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
. (Join-Path $PSScriptRoot 'lib/mahabbat-common.ps1')
. (Join-Path $PSScriptRoot 'lib/mahabbat-backup-crypto.ps1')

function Read-MahabbatSetupEnvFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $map = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { $map[$matches[1]] = $matches[2].Trim() }
  }
  Remove-MahabbatFileSecure -Path $Path
  return $map
}

try {
  $root = Get-MahabbatRoot
  $fromFile = @{}
  if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { throw 'Файл secrets не найден.' }
    $fromFile = Read-MahabbatSetupEnvFile -Path $EnvFile
  }
  $rawEmail = if ($fromFile.ContainsKey('MAHABBAT_SETUP_EMAIL')) { [string]$fromFile['MAHABBAT_SETUP_EMAIL'] } else { $Email }
  $secret = if ($fromFile.ContainsKey('MAHABBAT_SETUP_PASSWORD')) { [string]$fromFile['MAHABBAT_SETUP_PASSWORD'] } else { $Password }
  $venueIn = if ($fromFile.ContainsKey('MAHABBAT_SETUP_VENUE')) { [string]$fromFile['MAHABBAT_SETUP_VENUE'] } else { $Venue }
  if ($PSCmdlet.ParameterSetName -eq 'Legacy' -and (-not [string]::IsNullOrWhiteSpace($Password))) {
    Write-Warning 'Параметры -Email/-Password устарели: пароль в argv виден в ps. Используйте -EnvFile.'
  }
  $email = $rawEmail.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($email) -or -not $email.Contains('@')) { throw 'Нужна корректная почта владельца.' }
  if ($secret.Length -lt 8 -or $secret.Length -gt 50) { throw 'Пароль должен быть 8-50 символов.' }

  $existing = Get-MahabbatEnvValue -Map (Get-MahabbatEnvMap) -Name 'TWENTY_API_KEY'
  if (-not [string]::IsNullOrWhiteSpace($existing)) {
    Write-Host 'Ключ уже создан ранее, повтор не нужен.'
    exit 0
  }

  Set-MahabbatEnvValueShim -Root $root -Name 'MAHABBAT_VENUE_EMAIL' -Value $email
  Set-MahabbatEnvAcl
  $serverContainer = Get-MahabbatServiceContainerId 'server'
  if ([string]::IsNullOrWhiteSpace($serverContainer)) { throw 'Сервер не запущен. Дождитесь конца шага запуска.' }
  $venueName = if ([string]::IsNullOrWhiteSpace($venueIn)) { Get-MahabbatVenueName } else { $venueIn }
  # Пароль — только через env дочернего docker exec (никогда в argv).
  $childEnv = @{ MAHABBAT_VENUE_PASSWORD = $secret }
  $secret = $null
  $previous = @{}
  foreach ($name in $childEnv.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
  try {
    foreach ($entry in $childEnv.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    $bootstrapOut = (& docker exec -i -e MAHABBAT_VENUE_EMAIL=$email -e MAHABBAT_VENUE_PASSWORD -e MAHABBAT_VENUE_NAME=$venueName -e MAHABBAT_VENUE_LOCALE=ru-RU $serverContainer yarn command:prod workspace:bootstrap:venue 2>&1) -join "`n"
  } finally {
    foreach ($name in $childEnv.Keys) {
      if ($null -eq $previous[$name]) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
      else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    Remove-Variable childEnv -ErrorAction SilentlyContinue
  }
  $matchKey = [regex]::Match($bootstrapOut, 'MAHABBAT_API_KEY=([A-Za-z0-9\-_\.]+)')
  if (-not $matchKey.Success) { Write-Host $bootstrapOut; throw 'Не удалось создать владельца автоматически.' }
  Set-MahabbatEnvValueShim -Root $root -Name 'TWENTY_API_KEY' -Value $matchKey.Groups[1].Value
  Set-MahabbatEnvValueShim -Root $root -Name 'MAHABBAT_API_KEY' -Value $matchKey.Groups[1].Value
  Set-MahabbatEnvAcl
  Remove-Variable bootstrapOut -ErrorAction SilentlyContinue
  Write-Host 'Владелец, рабочее пространство, русский язык и ключ созданы.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
