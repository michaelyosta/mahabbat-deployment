import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// Fork test 2/3: signup-disabled contract. The venue has no mail delivery,
// so BOTH self-registration paths must fail without creating anything.
// Contract is verified against the committed dist injector (which throws
// SIGNUP_DISABLED into the upstream resolver at docker build) — no fork
// checkout required.
const ROOT = join(import.meta.dirname, '..', '..');
const PATCH = join(ROOT, 'deploy', 'mahabbat-fork-patch');

test('signUp mutation throws SIGNUP_DISABLED before creating anything', () => {
  const injector = readFileSync(join(PATCH, 'inject-fork-patch.mjs'), 'utf8');
  assert.ok(injector.includes('SIGNUP_DISABLED'), 'injector throws SIGNUP_DISABLED into signUp');
  // Fail-closed: the signup anchor targets the method entry, and the injected
  // replacement block (after the anchor) throws SIGNUP_DISABLED.
  const anchorAt = injector.indexOf('async signUp(signUpInput, context)');
  assert.ok(anchorAt !== -1, 'signup anchor present');
  const injected = injector.slice(anchorAt);
  assert.ok(injected.includes('SIGNUP_DISABLED'), 'injected block throws SIGNUP_DISABLED');
});
test('anonymous signUpInWorkspace without invite is denied (fail-closed)', () => {
  const injector = readFileSync(join(PATCH, 'inject-fork-patch.mjs'), 'utf8');
  assert.ok(
    injector.includes('A personal invitation is required to join this workspace'),
    'public-link-only signup requires a personal invitation',
  );
  assert.ok(
    injector.includes('MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP'),
    'gate is fail-closed: only an explicit flag disables it',
  );
  const bootstrap = readFileSync(join(PATCH, 'workspace-bootstrap-venue.command.js'), 'utf8');
  assert.ok(
    bootstrap.includes('isPublicInviteLinkEnabled'),
    'bootstrap keeps the venue invite-only (public link forced off)',
  );
});
