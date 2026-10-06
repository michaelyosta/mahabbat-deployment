# Running Mahabbat

Fresh restaurant PC — one entrypoint (Russian-guided wizard):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\mahabbat-setup.ps1
```

It runs prerequisites → bootstrap → start, then guides the single manual
step (Twenty signup + API key), then runs metadata plan/apply with
confirmation, then seeds venue day-one data (zones, tables, menu, payments,
staff from private PINs in the local `.env`). Flags: `-SkipPrerequisites`,
`-SkipSeed`. Daily commands below remain for operation after setup.

Run these commands from the deployment repository root:

`bootstrap` fetches the locked inner repository and creates a local `.env`
with fresh runtime secrets if one does not exist. It never restores a
database. The reconstructed deployment has persistent named volumes, but the
legacy persistent state assessment is `UNAVAILABLE`.

Daily commands:

```powershell
.\scripts\mahabbat-start.ps1
.\scripts\mahabbat-status.ps1
.\scripts\mahabbat-doctor.ps1
.\scripts\mahabbat-logs.ps1
.\scripts\mahabbat-stop.ps1
.\scripts\mahabbat-backup.ps1
```

Local endpoints:

- CRM: http://localhost:3000/
- CRM health: http://localhost:3000/healthz
- POS: http://localhost:3100/
- POS health: http://localhost:3100/health

## Русский интерфейс CRM

Язык стандартной оболочки Twenty задаётся отдельно для каждого пользователя.
Для локального администратора он уже установлен как `Русский`; после входа
проверьте `Настройки → Опыт работы → Язык → Русский`. Настройка сохраняется
в профиле и переживает перезагрузку CRM.

В текущей рабочей области системная папка `Рабочие процессы` также переименована
через штатный редактор макета. Стандартные команды Twenty синхронизируются
отдельным идемпотентным скриптом на уровне рабочей области, поэтому основная
навигация CRM не смешивает английские и русские названия. Пользователю доступны русские названия
`Компании`, `Люди`, `Задачи`, `Заметки`, `Панели управления`, `Заказы`,
`Бронирования`, `Склад`, `Печать` и `Лояльность`.

У нового участника язык является его личной настройкой: после приглашения
откройте тот же экран профиля и выберите `Русский`. Бизнес-объекты Mahabbat,
POS, склад и печать уже содержат русские пользовательские подписи. Английские
имена API, полей, статусов в коде и тестовых файлов не переводятся: это
технические идентификаторы, а не текст рабочего интерфейса.

Стандартные подписи командного меню и системных индексных представлений Twenty
хранятся в метаданных рабочей области, а не в каталоге переводов интерфейса.
После установки или обновления
метаданных синхронизация выполняется автоматически. Её можно безопасно повторить
вручную:

```powershell
.\scripts\mahabbat-localize-ru.ps1
```

Скрипт изменяет только подписи стандартного командного меню текущей локальной
рабочей области, системные индексные представления `All …` → `Все …` и одну
известную локальную команду `Quick Lead` → `Быстрый лид`. Он сохраняет шаблоны
динамических названий объектов и не меняет исходный код Twenty. Остальные
команды приложения Mahabbat и технические идентификаторы API при этом не
затрагиваются.

## First application install

Owner and API key are provisioned headlessly — no browser signup.
`mahabbat-setup-owner.ps1` (wizard `/api/owner`) runs
`workspace:bootstrap:venue` inside the server container and writes
`TWENTY_API_KEY`/`MAHABBAT_API_KEY` to local `.env` itself. Console
`mahabbat-setup.ps1` does the same since the key-save fix. Keep
`TWENTY_APP_ACCESS_TOKEN` empty unless the supported app install flow
provides one.

```powershell
.\scripts\mahabbat-metadata.ps1 -Action plan
.\scripts\mahabbat-metadata.ps1 -Action apply [-Force]
```

`plan` is read-only and must be inspected before `apply`. `-Force` is needed
only when plan reports destructive changes (review them first). After apply, the
wrapper recreates only stateless services. Keep API credentials in the local
ignored environment only, then run the parity guard:

```powershell
Set-Location ..
yarn --cwd .\mahabbat-app verify-runtime-api-parity
yarn --cwd .\mahabbat-app test:unit
```

The full POS and Inventory acceptance scripts require private credentials and
synthetic namespaced fixtures. Do not run destructive cleanup against a real
workspace.

## Windows printers and routing

The host-side print gateway runs beside the Windows Print Spooler. The Docker
containers never enumerate Windows printers and the browser never receives a
printer service credential. `mahabbat-start.ps1` starts the gateway on the
configured local host port (default `0.0.0.0:3110`) and the backend calls it
through the authenticated internal route.

To connect or replace a printer:

1. Install the printer in Windows and confirm that Windows can see its queue.
2. Open Mahabbat → `Печать` and authenticate the local POS administrator.
3. Press `Обновить список`.
4. Choose the discovered queue and save a human-readable `PrinterDevice`.
5. Press `Тестовая печать`; the result means that the job was sent to the
   Windows queue, not that paper was physically confirmed.
6. Assign the device to `Кухня`, `Бар`, `Мангал`, `Пречек`, or another station.
   One device may serve multiple stations.
7. Press `Сохранить`. A later route change affects new jobs only; historical
   jobs keep their resolved destination snapshot.

The system queue name is the stable binding. If Windows removes or renames the
queue, Mahabbat shows `Не найден` and does not silently choose another printer.
Use the same screen to select and explicitly bind the replacement. The
compatibility status is deliberately `Совместимость не проверена` until a
driver/device provides reliable evidence; a virtual queue such as Microsoft
Print to PDF is not proof of ESC/POS paper compatibility.

Operational checks:

```powershell
.\scripts\mahabbat-status.ps1
.\scripts\mahabbat-doctor.ps1
Get-Printer
Get-Service Spooler
```

`status` reports the print gateway, discovered Windows printer count,
configured devices, and broken bindings. `doctor` checks the Windows Spooler,
gateway health, discovery, and missing bindings. The gateway is bound to the
local host by default in `.env.example`; retain the internal route secret and
do not expose this endpoint directly to a browser or an unauthenticated LAN.

### Temporary remote physical-print bridge

When the backend remains on the home PC and the physical printer is at the
restaurant, the existing inner Print Gateway can run on the restaurant
Windows PC. It polls the home resolver outbound and writes through the local
Windows Spooler or the existing Ethernet RAW TCP provider. No second print
agent and no public printer port are needed. The complete procedure is in the
inner repository's `docs/TEMPORARY_REMOTE_PRINT_BRIDGE.md`.

On the home deployment, set the private `.env` value:

```text
PRINT_GATEWAY_MODE=REMOTE
```

In this mode `mahabbat-start.ps1` deliberately does not start a local
dispatcher, so two gateways cannot claim the same `PrintJob`. The restaurant
PC uses `scripts\mahabbat-remote-print-gateway.ps1` with a private env file.
If `Настройки → Печать` must enumerate restaurant Windows queues, provide an
existing private return path to the gateway; do not publish `3110` or `9100`.
Restore `PRINT_GATEWAY_MODE=LOCAL` and stop/remove the temporary restaurant
process after the physical test phase.

### Portable package for the restaurant PC

For a temporary remote physical test, the deployment repository can build a
private portable package around the same existing gateway. The package does
not install a permanent service, does not contain the repository or
`node_modules`, and does not require the restaurant operator to install Node,
Docker, Git, or use PowerShell. Windows' built-in printer component is called
internally by the bundled gateway; the operator only uses the small status
window.

Build it from the deployment repository after the inner repository is present:

```powershell
.\scripts\mahabbat-package-print-bridge.ps1
```

The builder checks the Node version recorded in `mahabbat-app\.nvmrc`. If
the developer machine has a different Node installation, pass the path to a
matching `node.exe` with `-NodePath`; this affects only package creation, not
the restaurant operator.

The script creates the locally ignored
`artifacts\print-bridge\Mahabbat-Print-Bridge-v1.2-private.zip`. It takes the
remote origin from the documented pilot hostname by default and copies only
the local `MAHABBAT_INTERNAL_ROUTE_SECRET` into the private ZIP. Optional
Cloudflare Access service-token variables are copied only when both private
values are present in the local environment. They are never printed, put in
the package UI, or committed. The builder snapshots station/device labels
when the local workspace is available; an empty snapshot does not prevent the
bridge from discovering a Windows queue and sending jobs.

The builder runs an isolated package self-test before creating the ZIP. It
checks the bundled runtime, local status UI, HMAC polling, Windows discovery
endpoint, normal test-print command boundary, and the existing simulator. The
test uses a temporary local resolver and never contacts the restaurant or
the public pilot origin.

Send the private ZIP directly to the specific restaurant PC. The operator
opens `Mahabbat Print Bridge.vbs`; the window is bound to `127.0.0.1` and
opens automatically. The normal flow is documented inside the package in
`RESTAURANT_PRINT_QUICKSTART.txt`: install the queue in Windows, refresh the
list, select and save it, then press `Тестовая печать`. The package keeps HMAC
and optional Access headers in its private process; the browser/UI receives
neither credential.

If a network printer is intentionally not installed as a Windows queue, the
package has a collapsed fallback for an explicitly supplied printer IP/host
and port. It validates the host and port and sends the same `testPrinterDevice`
command through the existing RAW TCP gateway; it does not assume port 9100.
The normal Windows-queue flow remains the recommended path.

The package uses the existing remote `PrintJob` polling path. A successful
status means the job reached the configured transport path, not that paper
was physically confirmed. Soft Group 8256, Cyrillic-on-paper, 80 mm geometry,
cutter and network/offline recovery remain `PENDING RESTAURANT` until the
real device is connected and photographed. Do not publish port 3110 or RAW
printer port 9100, and do not add the private ZIP to Git.

## Cloudflare (optional, venue-owned)

Public endpoints are optional. A LAN-only venue PC needs no tunnel: leave
`MAHABBAT_TUNNEL_NAME`, `MAHABBAT_PUBLIC_CRM_URL` and `MAHABBAT_PUBLIC_POS_URL`
empty in the local `.env`. `mahabbat-status.ps1` and `mahabbat-doctor.ps1`
report `LOCAL ONLY` and skip cloudflared checks in that case.

When the venue wants public URLs, set the three values in the local `.env`
(never in Git):

```text
MAHABBAT_TUNNEL_NAME=<venue-tunnel-name>
MAHABBAT_PUBLIC_CRM_URL=https://<venue-crm-host>
MAHABBAT_PUBLIC_POS_URL=https://<venue-pos-host>
```

The token file is derived from the tunnel name:
`.cloudflared\<tunnel-name>.token`. Install the official `cloudflared`
binary, then obtain the tunnel token from Cloudflare Zero Trust → Networks →
Tunnels → `<venue-tunnel-name>` → Add a connector. Store it in that local
ignored file.

```powershell
winget install --id Cloudflare.cloudflared --exact --source winget
.\scripts\mahabbat-cloudflared.ps1 -Action status
```

The start script uses an installed Windows service when available. If service
installation requires elevation, it can run the connector as a hidden
user-mode process from the token file:

```powershell
.\scripts\mahabbat-cloudflared.ps1 -Action start
.\scripts\mahabbat-status.ps1
```

An Administrator PowerShell may instead install the service explicitly:

```powershell
.\scripts\mahabbat-cloudflared.ps1 -Action install -TokenFile .\.cloudflared\<tunnel-name>.token
```

The previous pilot configuration (`mahabbat-pilot-review`,
`crm-pilot.showalove.ru`, `pos-pilot.showalove.ru`) is one venue instance of
this pattern, not a default. Do not reuse its `Bypass / Everyone` Access
policy for a production deployment.

## Backup and restore

Create a PostgreSQL custom-format dump (manual encrypted copy):

```powershell
$env:MAHABBAT_BACKUP_PASSWORD = '<copy-password-10-plus-chars>'
.\scripts\mahabbat-backup.ps1
```

With `$env:MAHABBAT_BACKUP_PASSWORD` set (10+ characters) the dump is
encrypted to `database.dump.enc` — AES-256-CBC + HMAC-SHA256, key from
PBKDF2-HMAC-SHA256 with 200000 iterations — verified by decrypting to a temp
file and running `pg_restore --list` inside the PostgreSQL container, and only
then is the plaintext shredded. The manifest records `encrypted:true` plus the
KDF parameters; it never contains the password or keys. Together with every
encrypted manual copy a `RECOVERY-SHEET.txt` is written next to the dump
(date, SHA256, verify/restore commands — no secrets).

The password is never passed on the command line. The wizard (page "Daily
work") and the tray icon ask for it with a password dialog for manual copies;
the wizard and tray default to the encrypted mode and show an honest warning
label for the plain mode. There is no recovery without
the copy password — write it down separately from this computer.
`backups/` is ignored by Git.

Nightly 04:00 tray copy is encrypted with a DPAPI machine key
(`.private/backup-nightly.dpapi`, CurrentUser scope, user-only ACL): no paper
password exists for it and none needs to be stored. Manual copies always use
the paper password. Explicit plaintext is only available with the deliberate
fallback flag and prints a warning:

```powershell
.\scripts\mahabbat-backup.ps1 -NonInteractive -AllowPlaintext
```

Check a copy password WITHOUT restoring (HMAC-only, no decrypt, no restore):

```powershell
.\scripts\mahabbat-verify-password.ps1 -BackupPath .\backups\<timestamp>
```

Restore is never part of startup and requires `-ConfirmRestore`:

```powershell
.\scripts\mahabbat-restore.ps1 -BackupPath .\backups\<timestamp> -ConfirmRestore
```

An encrypted manual backup asks for the copy password after confirmation and
refuses before stopping any service when the password is wrong or the file is
damaged. A nightly DPAPI copy unlocks with the same Windows user profile and
asks for no password. The decrypted temp file is wiped after the restore.

Restore preflight (do all three before any material restore):

```powershell
.\scripts\mahabbat-backup.ps1            # 1. fresh backup first
$env:MAHABBAT_BACKUP_PASSWORD = '<copy-password>'
.\scripts\mahabbat-verify-password.ps1 -BackupPath .\backups\<timestamp>  # 2. HMAC check
```

3. Dry-run list the dump inside the PostgreSQL container (read-only, changes
nothing), then restore. If `pg_restore` fails mid-restore, application
services stay stopped for inspection — bring them back explicitly:

```powershell
.\scripts\mahabbat-start.ps1
.\scripts\mahabbat-status.ps1
```

A restore may overwrite the live database and stops application services
while it runs.

## Ротация ссылки-приглашения

Персональная ссылка-приглашение (`http://localhost:3000/invite/<hash>`) одна на заведение. Ротируйте её при утечке ссылки или уходе сотрудника: `.\scripts\mahabbat-rotate-invite.ps1` (предпросмотр без записи: `-DryRun` или `-WhatIf`) генерирует новый `inviteHash` (uuid), одной операцией `UPDATE core.workspace` через контейнер `db` печатает новую ссылку и предупреждает, что старая сразу мертва. При остановленной или неготовой БД скрипт громко падает и ничего не меняет.

## Common failures

- Docker unavailable: start Docker Desktop, then run `mahabbat-doctor.ps1`.
- Missing `.env`: run `mahabbat-bootstrap.ps1`; do not copy secrets into Git.
- Lock mismatch or dirty inner tree: inspect the inner repository before any
  checkout; never use `git reset --hard` automatically.
- Local health passes but public URL is down: check the cloudflared process or
  Windows service and the tunnel status in Cloudflare; verify local origins.
- Printer list is empty: verify that the Windows `Spooler` service is running,
  `Get-Printer` works in PowerShell, and `mahabbat-status.ps1` reports a healthy
  print gateway.
- A configured printer is unavailable: refresh `Печать`, verify the exact
  Windows queue name, and explicitly rebind the device; Mahabbat never falls
  back to another queue.
- Test print fails: inspect `mahabbat-status.ps1`, `mahabbat-doctor.ps1`, and
  `.private\print-gateway.log`. The configured queue may be unavailable or its
  driver may not accept RAW ESC/POS data. Physical paper, Cyrillic, 80 mm, and
  cutter acceptance remain a separate hardware test.
- POS opens but cannot authenticate: verify the Mahabbat App metadata is
  applied and a private service/API credential is present in `.env`.
- Worker is running but logic does not apply: verify `LOGIC_FUNCTION_TYPE=LOCAL`,
  `SERVER_URL=http://server:3000`, Redis health, and runtime parity.

Never run `docker compose down -v` or `docker volume prune` for this stack.
