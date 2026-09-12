# Mahabbat disaster-recovery evidence

Assessment date: 2026-09-12 (Asia/Qyzylorda)

## Canonical sources

- Inner repository: `https://github.com/michaelyosta/mahabbat-crm.git`
- Inner checkpoint: `8b2dab8b221db83b9f2f73d2043f80709895a007`
- `origin/main` matched that checkpoint and the inner worktree was clean.
- Reconstructed outer repository: `michaelyosta/mahabbat-deployment` (private user-controlled repository).

The outer layer does not vendor or alter Twenty core. It fetches the inner repository into `mahabbat-app` and builds the existing `pos-standalone/Dockerfile` from that context.

## Twenty baseline

- Repository: `https://github.com/twentyhq/twenty.git`
- Selected ref: `twenty/v2.29.0`
- Selected commit: `7f0bae5b5f5e6f907512fa0139c6b1e704d3dc15`
- Current `main` observed during reconstruction: `b782836bca6841bf735026d2223bbb22a65019a6`
- Selected image: `twentycrm/twenty:v2.29.0`

The v2.29.0 baseline matches the inner repository's Twenty SDK/client constraints. The branding image is a deployment overlay over the official image; no Twenty source files are patched.

## Legacy data discovery

`legacy-data-status.json` is the machine-readable decision record. The result is:

`LEGACY PERSISTENT DATA: UNAVAILABLE`

Evidence available on this device and in the connected Cloudflare account:

- Both old public hostnames reached Cloudflare Access login (HTTP 302), not an authenticated CRM/POS runtime.
- At the time of legacy-data assessment, existing tunnel `mahabbat-pilot-review` was `Down`, with zero active connectors.
- Its published routes and Access applications were preserved and inspected; no `Allow Everyone` policy was observed.
- Before starting the reconstructed stack, Docker had no Mahabbat containers, images, or named volumes.
- The known local recovery paths `.mahabbat-demo-recovery`, `.mahabbat-selfhost-api-key`, and `.cloudflared` were absent.
- No Mahabbat/PostgreSQL dump, SQL export, volume archive, or full project archive was found in the accessible Documents/user paths.
- No destructive action was taken against the old public endpoints or Cloudflare configuration.

No legacy database was restored. The current database is a newly created empty PostgreSQL workspace on persistent named volumes.

## Reconstructed runtime

The local stack is:

- PostgreSQL 16 on named volume `mahabbat_db-data`
- Redis 7 on named volume `mahabbat_redis-data`
- Twenty server and worker on the pinned v2.29.0 image with branding overlay
- Standalone Mahabbat POS built from `mahabbat-app/pos-standalone/Dockerfile`

Verified local endpoints:

- CRM: `http://localhost:3000`
- POS: `http://localhost:3100`

The existing Cloudflare hostname routes remain `crm-pilot.showalove.ru -> localhost:3000` and `pos-pilot.showalove.ru -> localhost:3100`. The same tunnel was subsequently connected from this device with the existing token. The connector runs as a hidden user-mode process because Windows Service Control Manager requires an Administrator session on this host.

## Verification

- PowerShell scripts: parse pass.
- Local Docker compose config: pass.
- One-command local start: pass.
- Existing Cloudflare tunnel connector: pass; both public hostnames return the expected Access login response (HTTP 302).
- Unit suite: 23 files / 285 tests passed.
- Standalone POS suite: 7/7 passed.
- Printing simulator suite: 9/9 passed.
- Full integration suite was intentionally not claimed: the fresh workspace has no Twenty API key and no metadata application has been run yet.
