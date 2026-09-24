[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'scripts\pilot-common.ps1')

try {
  $root = Get-PilotRoot
  Assert-PilotMachineBinding | Out-Null
  Start-PilotDockerDesktop
  $license = Get-PilotLicenseStatus
  if (-not $license.active) { throw 'Сначала активируйте лицензию файлом, выпущенным для этой установки.' }

  $envMap = Get-PilotEnvMap
  $apiKey = Get-PilotEnvValue $envMap 'MAHABBAT_API_KEY' (Get-PilotEnvValue $envMap 'TWENTY_API_KEY')
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host 'Создайте локальный ключ в CRM: Настройки → Разработчики → API и вебхуки → API-ключи.'
    Write-Host 'Это ключ только данного компьютера. Он будет скрыто сохранён в локальной конфигурации; значение не выводится.'
    $secureKey = Read-Host 'Вставьте локальный API-ключ' -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
      $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
      $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim()
    } finally {
      if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    if ($apiKey.Length -lt 24 -or $apiKey -match '[\r\n\s]') { throw 'Формат введённого ключа не принят. Создайте новый локальный API-ключ и повторите.' }
    Set-PilotEnvValues @{ TWENTY_API_KEY = $apiKey; MAHABBAT_API_KEY = $apiKey }
  }

  Invoke-PilotCompose @('up', '-d')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw 'Сервисы не готовы. Проверьте status.ps1; данные не изменены.' }

  $node = Join-Path $root 'runtime\node\node.exe'
  $installer = Join-Path $root 'runtime\installer\mahabbat-app-installer.mjs'
  if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or -not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw 'В пакете отсутствует мастер установки Mahabbat. Повторно распакуйте release ZIP.'
  }

  $privateRoot = [IO.Path]::GetFullPath((Join-Path $root '.private'))
  $cliProfile = Join-Path $privateRoot 'twenty-cli-profile'
  New-Item -ItemType Directory -Force -Path $cliProfile | Out-Null
  Protect-PilotPrivatePath -Path $cliProfile -Directory
  $previousUserProfile = $env:USERPROFILE
  $previousPilotRoot = $env:MAHABBAT_PILOT_ROOT
  $success = $false
  try {
    $env:USERPROFILE = $cliProfile
    $env:MAHABBAT_PILOT_ROOT = $root
    & $node $installer
    if ($LASTEXITCODE -ne 0) { throw 'Мастер не смог применить приложение. Проверьте локальный API-ключ и повторите попытку.' }
    $success = $true
  } finally {
    if ($null -eq $previousUserProfile) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $previousUserProfile }
    if ($null -eq $previousPilotRoot) { Remove-Item Env:MAHABBAT_PILOT_ROOT -ErrorAction SilentlyContinue } else { $env:MAHABBAT_PILOT_ROOT = $previousPilotRoot }
  }

  if ($success -and (Test-Path -LiteralPath $cliProfile -PathType Container)) {
    $resolvedProfile = [IO.Path]::GetFullPath($cliProfile)
    $privatePrefix = $privateRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedProfile.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Небезопасная временная папка SDK.' }
    Remove-Item -LiteralPath $resolvedProfile -Recurse -Force
  }

  Invoke-PilotCompose @('up', '-d', '--force-recreate', 'server', 'worker', 'pos-gateway')
  if (-not (Wait-PilotRuntime -TimeoutSeconds 600)) { throw 'Приложение применено, но перезапуск runtime не завершён. Проверьте status.ps1.' }
  Start-PilotPrintGateway
  $installed = [ordered]@{
    schema_version = 1
    app_version = '0.9.0'
    application_universal_identifier = '21bf1410-15f6-452d-bfd7-8d0d1601710b'
    installed_at = [DateTime]::UtcNow.ToString('o')
  }
  $marker = Join-Path $root 'config\app-installed.json'
  [IO.File]::WriteAllText($marker, ($installed | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))
  Write-Host 'MAHABBAT_APP_INSTALL=PASS'
  Write-Host 'Схема и runtime обновлены; служебный ключ хранится только локально.'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
