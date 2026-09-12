# Mahabbat deployment

This repository is the reconstructed, user-controlled deployment layer for
the canonical Mahabbat application. It keeps Twenty upstream pinned at
`twenty/v2.29.0` and fetches the inner application into `mahabbat-app/` at the
SHA recorded in `mahabbat-inner.lock.json`.

Legacy persistent data assessment is recorded in `legacy-data-status.json`.
The current recovery decision is `UNAVAILABLE`; the first runtime created by
this repository is therefore a new workspace, not a restore of old CRM/POS
data.

See [docs/RUNNING_MAHABBAT.md](docs/RUNNING_MAHABBAT.md) for the operational
cheat sheet.

