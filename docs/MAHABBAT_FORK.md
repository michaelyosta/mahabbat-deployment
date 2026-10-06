# Mahabbat Twenty fork — headless venue bootstrap

Base: `twentyhq/twenty` at `twenty/v2.29.0` (`7f0bae5b`).
Checkout: sparse (`auth`, `api-key`, `user`, `user-workspace`, `workspace`,
`database/commands`, `guards`, `captcha`, `translations`, `metadata`).

## Why a fork

Upstream self-hosted `:3000` cannot be provisioned without browser clicks:

1. `signUp` creates a user but no workspace (`signUpWithoutWorkspace`).
2. `signUpInNewWorkspace` requires `UserAuthGuard` — a session-bearing user,
   which headless automation cannot mint (no cookie jar, no browser).
3. `activateWorkspace` requires `UserAuthGuard + WorkspaceAuthGuard` — same
   blocker; the workspace stays `PENDING_CREATION` without it.
4. `createApiKey` requires `RequireAccessTokenGuard` — an ACCESS token, which
   requires `getAuthTokensFromLoginToken` with a login token from an
   authenticated flow.
5. `updateWorkspaceMemberSettings` (per-user Russian locale `ru-RU`) requires
   an authenticated member or `WORKSPACE_MEMBERS` setting permission.

Evidence: `auth.resolver.ts` (`signUp`, `signUpInNewWorkspace`,
`activateWorkspace`, `createApiKey` guards), `workspace.resolver.ts`
(`activateWorkspace` guards), `api-key.resolver.ts:72-74`
(ACCESS-token comment), `user.resolver.ts:460-562` (settings guards),
`jwt.auth.strategy.ts` (`validateWorkspaceAgnosticToken` returns user-only,
no workspace), `TWENTY_GAPS.md` (AuthResolver not mounted on `:3000`).

## Patch set (P1: 7 patches)

### 1. `workspace-bootstrap-venue.command.ts` (NEW, P1-hardened)

`workspace:bootstrap:venue` — one CLI command replacing all five browser
clicks. Runs inside the server container via `yarn command:prod`, so it
reuses every NestJS provider (transactions, hashing, guards bypassed by
construction — CLI is already privileged):

- validates env: `MAHABBAT_VENUE_EMAIL`, `MAHABBAT_VENUE_PASSWORD` (8-50
  chars, `PASSWORD_REGEX`), `MAHABBAT_VENUE_NAME`, optional
  `MAHABBAT_VENUE_LOCALE` (default `ru-RU`), `MAHABBAT_VENUE_SUBDOMAIN`;
- idempotent: existing user by email is reused, not duplicated — P1: reuse
  verifies the supplied password against the stored hash; mismatch rotates
  the password in (`saveUserForBootstrapVenue`), missing hash (SSO-created
  user) fails loudly instead of silently reusing;
- `signUpWithoutWorkspace` (user + server-admin grant when first);
- `signUpOnNewWorkspace` (workspace, or reuse the user's existing one);
- `activateWorkspace` (schema, roles, member, prefill, flags) + enforce
  `isPublicInviteLinkEnabled=false` on the venue workspace;
- `updateUserWorkspaceLocaleForUserWorkspace` (ru-RU shell);
- key reuse (P1): filter active (not revoked, not expired) + admin-role
  membership via `ApiKeyRoleService.getRolesByApiKeys` + `ORDER BY
  createdAt DESC` (newest first); anything else mints a fresh admin key
  (`apiKeyService.create` + `generateApiKeyToken`, admin role, 100y);
- prints `MAHABBAT_API_KEY=<token>` and `MAHABBAT_WORKSPACE_ID=<id>` to
  stdout — the ONLY secret-bearing output, consumed by the setup wizard.

### 2. `generate-api-key.command.ts` (1 guard)

`workspace:generate-api-key` refuses to run outside dev/test
(`NODE_ENV` gate, lines 83-92). The venue needs the same command in
production self-host. Patch: allow `production` when the explicit
`--allow-production` flag is passed. No behavior change without the flag.

### 3. `auth.service.ts` — personal-invite gate (P1)

`checkAccessForSignIn`: a bare public invite-hash link no longer suffices —
password signup requires a personal (email-bound) invitation. Fail-closed:
enforced unless `MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP` is
literally `'false'`. Trusted approved-domains still bypass (unchanged).
`signInUpWithSocialSSO` (Google/Microsoft): same gate, relaxable with
`MAHABBAT_SSO_SIGNUP_INVITE_MODE=personal-or-public` (documented risk
acceptance). Catch-all helper `mahabbatIsCatchAllSignupDomain` backs the
setup-time warning: NEVER approve gmail.com, mail.ru, yandex.ru,
outlook.com & co. as trusted domains — that silently opens signup to
everyone with such a mailbox.

### 4. `sso-auth.controller.ts` — SAML/OIDC gate (P1)

Same personal-invite gate for enterprise SSO when it arrives on a bare
public invite-hash link for a foreign workspace. The common case (IdP
pinned to its own workspace, no invite hash) is untouched. Same
`personal-or-public` escape hatch.

### 5. `workspace.entity.ts` — public links default OFF (P1)

`isPublicInviteLinkEnabled` column default `true` → `false`. New venue rows
must opt in explicitly; existing rows need a data migration on rebase
(see checklist). Paired with the bootstrap enforcement above.

### 6. `user.service.ts` — bootstrap password seam (P1)

`saveUserForBootstrapVenue`: narrow persistence seam for the
verify-or-rotate step. No other caller should use it.

### 7. dist mirror (`deploy/mahabbat-fork-patch/`)

`workspace-bootstrap-venue.command.js` mirrors the TS command (verify /
rotate, public-link OFF, admin-role key filter, new `ApiKeyRoleService`
ctor dep + `design:paramtypes`); `inject-fork-patch.mjs` registers the
module imports. The auth gates (3–5) are source patches applied to the
fork checkout and baked by the image build.

## Signup bypass matrix (P1)

| Path | No invite | Public link only | Personal invite | Trusted domain |
|---|---|---|---|---|
| `signUpInWorkspace` (password) | deny (`User does not have access`) | deny (`A personal invitation is required…`, fail-closed) | allow | allow (unchanged) |
| `signInUpWithSocialSSO` (Google/Microsoft) | existing flow (no workspace → exchange token) | deny unless `personal-or-public` | allow | allow (unchanged) |
| SAML/OIDC callback | IdP-pinned flow (unchanged) | deny on foreign-workspace link unless `personal-or-public` | allow | allow (unchanged) |
| `signUp` (global) | disabled (`SIGNUP_DISABLED`, pre-existing P0) | — | — | — |
| Bootstrap CLI | n/a (privileged, requires `docker exec`) | n/a | n/a | n/a |

Escape hatches (both fail-closed, both logged at startup by compose
defaults): `MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP=false`
disables the password gate; `MAHABBAT_SSO_SIGNUP_INVITE_MODE=
personal-or-public` relaxes SSO only. Single-venue deployments SHOULD leave
  both at their defaults.

## What is NOT patched

- No auth guard weakened. No resolver signature changed. No GraphQL schema
  change. No permission model change. No billing, SSO, captcha, email flow
  change. Frontend untouched.
- `signUp`, `signIn`, `activateWorkspace`, `createApiKey` resolvers keep
  their guards for every network caller. The CLI path is privileged by
  design (requires `docker exec` on the venue PC itself).

## Upgrade policy (rebase checklist)

- Fork tracks `twenty/vX.Y.Z` tags. Rebase: re-apply the 7 patches onto the
  new tag, then:
  1. `git diff` the new tag for `auth.service.ts checkAccessForSignIn`, `sso-auth.controller.ts generateLoginToken`,
     `workspace.entity.ts isPublicInviteLinkEnabled`, `database-command.module.ts`, `generate-api-key.command.ts` —
     re-anchor every injector/patch string.
  2. Data migration: existing workspaces keep their stored `isPublicInviteLinkEnabled`; venue workspaces need
     `UPDATE core.workspace SET "isPublicInviteLinkEnabled" = false` unless public links are intended.
  3. Run `auth` + `api-key` unit suites (incl. the Mahabbat personal-invite specs) against the new tag.
  4. Rebuild the venue image (`mahabbat-twenty:vX.Y.Z-venue`) and re-run `gateway-limits.test.mjs` + `gateway.test.mjs`.
- If upstream ever ships a supported headless bootstrap (env-driven first
  user or CLI provision command), drop this fork and consume it.


## Image digests (P2)

Base images are pinned by digest, not tag alone (`image-digests.lock.json`):
`postgres:16-alpine`, `redis:7-alpine` in `docker-compose.yml`,
`twentycrm/twenty:v2.29.0` in both Dockerfiles, `node:24-bookworm` for the
metadata CLI (`scripts/mahabbat-metadata.ps1`), `node:24-alpine` for the POS
gateway build/runtime. `mahabbat-start.ps1` asserts the running db/redis
digests match the lock (fail-closed); CI asserts every FROM/compose pin plus
log rotation, the metadata CLI pin, and the installer Node-source hygiene.
Refresh: `docker pull <ref>` then
`docker image inspect <ref> --format '{{.RepoDigests}}'`, and record the new
pinned ref in the lock. Rebuild + rerun the fork tests after any digest bump.
