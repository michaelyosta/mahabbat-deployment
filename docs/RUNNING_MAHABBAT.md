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

## First application install

After the local Twenty server is healthy, provision a local Twenty API key
for the new workspace and place it only in `.env` as `TWENTY_API_KEY` and/or
`TWENTY_APP_ACCESS_TOKEN`. Then run the existing Apps SDK apply workflow from
`mahabbat-app` using the pinned `twenty-sdk@2.29.0`:

```powershell
Set-Location .\mahabbat-app
yarn install
$env:TWENTY_API_URL = 'http://localhost:3000'
$env:MAHABBAT_API_URL = 'http://localhost:3000'
yarn twenty apply -r selfhost-container
```

Keep API credentials in the private shell or local ignored environment only.
After metadata apply, recreate only stateless services if the generated
runtime layer is stale, then run the existing parity and acceptance checks:

```powershell
Set-Location ..
yarn --cwd .\mahabbat-app verify-runtime-api-parity
yarn --cwd .\mahabbat-app test:unit
```

The full POS and Inventory acceptance scripts require private credentials and
synthetic namespaced fixtures. Do not run destructive cleanup against a real
workspace.

## Cloudflare

The existing Cloudflare configuration is preserved in the account:

- tunnel: `mahabbat-pilot-review`
- CRM route: `crm-pilot.showalove.ru` → `http://localhost:3000`
- POS route: `pos-pilot.showalove.ru` → `http://localhost:3100`
- both hostnames remain behind Cloudflare Access

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

Do not create another tunnel, alter DNS, disable Access, or enable Allow
Everyone. The connector should be running before public smoke tests.

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
- POS opens but cannot authenticate: verify the Mahabbat App metadata is
  applied and a private service/API credential is present in `.env`.
- Worker is running but logic does not apply: verify `LOGIC_FUNCTION_TYPE=LOCAL`,
  `SERVER_URL=http://server:3000`, Redis health, and runtime parity.

Never run `docker compose down -v` or `docker volume prune` for this stack.
