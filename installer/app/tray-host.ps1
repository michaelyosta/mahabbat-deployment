# Mahabbat tray host: Windows NotifyIcon возле часов.
# Касса / CRM / Проверка / Копия / Стоп — без терминала.
# Запускается из автозагрузки после установки.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deployRoot = [IO.Path]::GetFullPath((Join-Path $appDir '..'))
$nodeExe = Join-Path $appDir 'runtime\node.exe'
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) {
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
}

function Invoke-TrayNode {
  param([string[]]$Arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeExe
  $psi.Arguments = (($Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' ')
  $psi.WorkingDirectory = $appDir
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit(15000)
  return $out
}
function Get-MahabbatState {
  try {
    $out = Invoke-TrayNode @('tray.mjs', '--json', '--root', $deployRoot)
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return ($out.Trim() | ConvertFrom-Json)
  } catch { return $null }
}

function Show-MahabbatBackupPasswordDialog {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Mahabbat — копия'
  $form.Width = 380
  $form.Height = 280
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $plain = New-Object System.Windows.Forms.RadioButton
  $plain.Text = 'Обычная копия (без шифрования — не рекомендуется)'
  $plain.Checked = $false
  $plain.Left = 16; $plain.Top = 12; $plain.Width = 330
  $enc = New-Object System.Windows.Forms.RadioButton
  $enc.Text = 'Зашифрованная копия (с паролем)'
  $enc.Checked = $true
  $lbl1 = New-Object System.Windows.Forms.Label
  $lbl1.Text = 'Пароль копии (10+ символов):'
  $lbl1.Left = 16; $lbl1.Top = 62; $lbl1.Width = 330
  $pw1 = New-Object System.Windows.Forms.TextBox
  $pw1.UseSystemPasswordChar = $true
  $pw1.Left = 16; $pw1.Top = 84; $pw1.Width = 330
  $lbl2 = New-Object System.Windows.Forms.Label
  $lbl2.Text = 'Повторите пароль:'
  $lbl2.Left = 16; $lbl2.Top = 112; $lbl2.Width = 330
  $pw2 = New-Object System.Windows.Forms.TextBox
  $pw2.UseSystemPasswordChar = $true
  $pw2.Left = 16; $pw2.Top = 134; $pw2.Width = 330
  $remember = New-Object System.Windows.Forms.CheckBox
  $remember.Text = 'Я записал(а) пароль'
  $remember.Left = 16; $remember.Top = 162; $remember.Width = 330
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = 'OK'; $ok.DialogResult = 'OK'
  $ok.Left = 190; $ok.Top = 196; $ok.Width = 80
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Отмена'; $cancel.DialogResult = 'Cancel'
  $cancel.Left = 276; $cancel.Top = 196; $cancel.Width = 80
  $form.Controls.AddRange(@($plain, $enc, $lbl1, $pw1, $lbl2, $pw2, $remember, $ok, $cancel))
  $form.AcceptButton = $ok
  $form.CancelButton = $cancel
  $toggle = {
    $on = $enc.Checked
    $lbl1.Enabled = $on; $pw1.Enabled = $on
    $lbl2.Enabled = $on; $pw2.Enabled = $on
    $remember.Enabled = $on
  }
  $plain.add_CheckedChanged($toggle)
  $enc.add_CheckedChanged($toggle)
  &$toggle
  $result = $form.ShowDialog()
  if ($result -ne 'OK') { $form.Dispose(); return $null }
  if (-not $enc.Checked) { $form.Dispose(); return '' }
  if ($pw1.Text.Length -lt 10 -or $pw1.Text.Length -gt 128) {
    [System.Windows.Forms.MessageBox]::Show('Пароль копии — 10–128 символов.', 'Mahabbat')
    $form.Dispose(); return $null
  }
  if ($pw1.Text -cne $pw2.Text) {
    [System.Windows.Forms.MessageBox]::Show('Пароли копии не совпадают.', 'Mahabbat')
    $form.Dispose(); return $null
  }
  if (-not $remember.Checked) {
    [System.Windows.Forms.MessageBox]::Show('Подтвердите, что записали пароль: без него копию не восстановить.', 'Mahabbat')
    $form.Dispose(); return $null
  }
  $password = $pw1.Text
  $pw1.Text = ''; $pw2.Text = ''
  $form.Dispose()
  return $password
}

function Invoke-MahabbatTrayBackupProcess {
  param([string]$Password, [switch]$Nightly)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeExe
  $psi.Arguments = '"tray.mjs" "--backup-now" "--root" "{0}"' -f $deployRoot
  $psi.WorkingDirectory = $appDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($Nightly) {
    # Ночная копия: DPAPI Unprotect здесь, base64 в env дочернего процесса.
    . (Join-Path $deployRoot 'scripts\lib\mahabbat-common.ps1')
    . (Join-Path $deployRoot 'scripts\lib\mahabbat-backup-crypto.ps1')
    New-MahabbatNightlyBackupKey | Out-Null
    $psi.EnvironmentVariables['MAHABBAT_BACKUP_NIGHTLY_B64'] = (Read-MahabbatNightlyBackupKeyBase64)
  } elseif ($Password -ne '') {
    $psi.EnvironmentVariables['MAHABBAT_BACKUP_PASSWORD'] = $Password
  } else {
    throw 'Ручная копия без пароля запрещена: выберите зашифрованную копию и введите пароль.'
  }
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err }
}

function Show-MahabbatTrayBackupResult {
  param([pscustomobject]$Result)
  if ($Result.ExitCode -eq 0) {
    $notify.ShowBalloonTip(10000, 'Mahabbat', 'BACKUP OK: резервная копия готова.', 'Info')
  } else {
    $tail = ((($Result.Out + "`n" + $Result.Err) -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join "`n"
    if ([string]::IsNullOrWhiteSpace($tail)) { $tail = 'подробности в логе резервного копирования' }
    $notify.ShowBalloonTip(15000, 'Mahabbat', ("BACKUP FAILED:`n{0}" -f $tail), 'Error')
  }
}

function Start-MahabbatTrayBackup {
  $password = Show-MahabbatBackupPasswordDialog
  if ($null -eq $password) { return }
  [System.Windows.Forms.MessageBox]::Show('Делаю резервную копию. Это займёт около минуты.', 'Mahabbat')
  $result = Invoke-MahabbatTrayBackupProcess -Password $password
  $password = ''
  Show-MahabbatTrayBackupResult $result
}

function Invoke-MahabbatTrayUpdateCheckProcess {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeExe
  $psi.Arguments = '"tray.mjs" "--check-update" "--json-update" "--root" "{0}"' -f $deployRoot
  $psi.WorkingDirectory = $appDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out; Err = $err }
}

function Start-MahabbatTrayUpdateCheck {
  param([switch]$Manual)
  $result = Invoke-MahabbatTrayUpdateCheckProcess
  $summary = 'Не удалось проверить обновления. Нужен интернет и вход в GHCR (docker login ghcr.io).'
  $kind = 'Warning'
  if ($result.ExitCode -eq 0) {
    try {
      $payloadText = (($result.Out -split "`r?`n") | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
      $payload = $payloadText | ConvertFrom-Json
      if ($payload.updateAvailable -eq 'yes') {
        $summary = ('Доступно обновление: {0}. Откройте установку и нажмите «Установить обновление» (нужна свежая копия).' -f $payload.available)
        $kind = 'Info'
      } elseif ($payload.updateAvailable -eq 'no') {
        $summary = 'Обновлений нет: стоит свежая версия.'
        $kind = 'Info'
      } else {
        $summary = 'Проверить обновления не удалось: реестр недоступен. Проверьте интернет и docker login ghcr.io.'
      }
    } catch { $summary = 'Проверка обновлений вернула непонятный ответ. Попробуйте позже.' }
  } else {
    $tail = ((($result.Out + "`n" + $result.Err) -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($tail)) { $summary = $tail }
  }
  if ($Manual -or $kind -eq 'Info') { $notify.ShowBalloonTip(15000, 'Mahabbat — обновления', $summary, $kind) }
}


$icon = [System.Drawing.SystemIcons]::Application
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $icon
$notify.Text = 'Mahabbat — запуск...'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$items = @{}
foreach ($def in @(
    @('open-pos', 'Открыть кассу'),
    @('open-crm', 'Открыть CRM'),
    @('status', 'Проверить систему'),
    @('update', 'Проверить обновления'),
    @('backup', 'Сделать копию сейчас'),
    @('rotate', 'Перевыпустить ключ доступа'),
    @('stop', 'Остановить Mahabbat'),
    @('start', 'Запустить Mahabbat'),
    @('exit', 'Выйти из трея')
  )) {
  $mi = $menu.Items.Add($def[1])
  $mi.Name = $def[0]
  $items[$def[0]] = $mi
}

$items['open-pos'].add_Click({ Start-Process 'http://localhost:3100/' })
$items['open-crm'].add_Click({ Start-Process 'http://localhost:3000/' })
$items['status'].add_Click({
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $deployRoot 'scripts\mahabbat-status.ps1')) -WorkingDirectory $deployRoot
})
$items['backup'].add_Click({
  Start-MahabbatTrayBackup
})
$items['update'].add_Click({
  Start-MahabbatTrayUpdateCheck -Manual
})
$items['rotate'].add_Click({
  $answer = [System.Windows.Forms.MessageBox]::Show('Перевыпустить ключ доступа? Старые сессии выйдут, касса переподключится примерно за 30 секунд. Открытые смены и продажи сохранятся.', 'Mahabbat', 'YesNo', 'Warning')
  if ($answer -eq 'Yes') {
    Start-Process -FilePath $nodeExe -ArgumentList @('tray.mjs', '--rotate-key', '--root', $deployRoot) -WorkingDirectory $appDir
  }
})
$items['stop'].add_Click({
  $answer = [System.Windows.Forms.MessageBox]::Show('Остановить Mahabbat? Касса и CRM станут недоступны, печать встанет. Данные сохранятся в volumes.', 'Mahabbat', 'YesNo', 'Warning')
  if ($answer -ne 'Yes') { return }
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $deployRoot 'scripts\mahabbat-stop.ps1')) -WorkingDirectory $deployRoot
})
$items['start'].add_Click({
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $deployRoot 'scripts\mahabbat-start.ps1')) -WorkingDirectory $deployRoot
})
$items['exit'].add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })

$notify.ContextMenuStrip = $menu
$notify.add_DoubleClick({ Start-Process 'http://localhost:3100/' })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.add_Tick({
  $state = Get-MahabbatState
  if ($null -eq $state) { $notify.Text = 'Mahabbat — нет связи'; return }
  $notify.Text = ('Mahabbat: касса {0}, CRM {1}, печать {2}' -f $state.pos, $state.crm, $state.print)
})
$timer.Start()

# Ежедневная копия в 04:00 — зашифрована DPAPI-ключом этого пользователя
# Windows (.private/backup-nightly.dpapi, user-only ACL). Бумажный пароль
# для ночной копии не нужен и не хранится.
$backupTimer = New-Object System.Windows.Forms.Timer
$backupTimer.Interval = 60000
$backupTimer.add_Tick({
  $now = Get-Date
  if ($now.Hour -eq 4 -and $now.Minute -lt 2) {
    $backupTimer.Stop()
    try {
      $result = Invoke-MahabbatTrayBackupProcess -Nightly
      Show-MahabbatTrayBackupResult $result
    } finally { $backupTimer.Start() }
  }
})
$backupTimer.Start()

# Проверка обновлений раз в сутки (09:07): только notify, никакого авто-применения.
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 60000
$updateTimer.add_Tick({
  $now = Get-Date
  if ($now.Hour -eq 9 -and $now.Minute -ge 7 -and $now.Minute -lt 9) {
    $updateTimer.Stop()
    try { Start-MahabbatTrayUpdateCheck } finally { $updateTimer.Start() }
  }
})
$updateTimer.Start()

[System.Windows.Forms.Application]::Run()
