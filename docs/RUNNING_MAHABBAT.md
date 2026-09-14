# Running Mahabbat

Run these commands from the deployment repository root:

```powershell
.\scripts\mahabbat-bootstrap.ps1
.\scripts\mahabbat-start.ps1
```

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

After the local Twenty server is healthy, provision a local Twenty API key
for the new workspace and place it only in `.env` as `TWENTY_API_KEY` and
`MAHABBAT_API_KEY`. Keep `TWENTY_APP_ACCESS_TOKEN` empty unless the supported
app install flow provides one. The outer wrapper runs the existing Apps SDK
workflow from `mahabbat-app` using the pinned `twenty-sdk@2.29.0`.

```powershell
.\scripts\mahabbat-metadata.ps1 -Action plan
.\scripts\mahabbat-metadata.ps1 -Action apply
```

`plan` is read-only and must be inspected before `apply`. After apply, the
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

## Cloudflare

The existing Cloudflare configuration is preserved in the account:

- tunnel: `mahabbat-pilot-review`
- CRM route: `crm-pilot.showalove.ru` → `http://localhost:3000`
- POS route: `pos-pilot.showalove.ru` → `http://localhost:3100`
- Cloudflare Access applications remain in place, but both pilot hostnames use
  an explicit `Bypass / Everyone` policy so the application login is the only
  user-facing login step

This is intentional for the development/pilot workspace. The tunnel, DNS,
TLS, and origin routes remain active; only the extra Cloudflare email/OTP gate
is bypassed. CRM still requires its Twenty login/password, and POS still
requires the Mahabbat staff PIN. Because the pilot hostnames are reachable
without Cloudflare identity authentication, do not reuse this policy for a
production deployment.

Install the official `cloudflared` binary, then obtain the existing tunnel
token from Cloudflare Zero Trust → Networks → Tunnels →
`mahabbat-pilot-review` → Add a connector. Store it in a local ignored file,
for example `.cloudflared\mahabbat-pilot-review.token`.

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
.\scripts\mahabbat-cloudflared.ps1 -Action install -TokenFile .\.cloudflared\mahabbat-pilot-review.token
```

Do not create another tunnel or alter DNS/routes. Keep the connector running
before public smoke tests. To restore the extra Cloudflare login later, remove
the pilot `Bypass / Everyone` policy from each application and restore the
owner-only `Allow` policy.

## Backup and restore

Create a PostgreSQL custom-format dump:

```powershell
.\scripts\mahabbat-backup.ps1
```

This creates `backups/<timestamp>/database.dump` and a secret-free
`backup-manifest.json`. `backups/` is ignored by Git. Restore is never part of
startup and requires both `-ConfirmRestore` and typing `RESTORE MAHABBAT`:

```powershell
.\scripts\mahabbat-restore.ps1 -BackupPath .\backups\<timestamp> -ConfirmRestore
```

Create and verify a fresh backup before any material restore. A restore may
overwrite the live database and stops application services while it runs.

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
