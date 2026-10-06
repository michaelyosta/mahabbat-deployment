import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// Fork test 2/3: signup-disabled GraphQL contract. The venue has no mail
// delivery, so BOTH self-registration paths must fail without creating
// anything — not just the global signUp. The TS source is the contract:
// signUp throws SIGNUP_DISABLED before any write, and the anonymous
// signUpInWorkspace-without-invite path is denied by checkAccessForSignIn.
const ROOT = join(import.meta.dirname, '..', '..');
const SRC = join(ROOT, 'mahabbat-twenty', 'packages', 'twenty-server', 'src');

test('signUp mutation throws SIGNUP_DISABLED before creating anything', () => {
  const resolver = readFileSync(
    join(SRC, 'engine', 'core-modules', 'auth', 'auth.resolver.ts'),
    'utf8',
  );
  const signUpBlock = resolver.slice(resolver.indexOf('async signUp('));
  const handler = signUpBlock.slice(0, signUpBlock.indexOf('async signUpInWorkspace('));
  assert.ok(handler.includes('SIGNUP_DISABLED'), 'signUp throws SIGNUP_DISABLED');
  // Fail-closed ordering: the throw precedes any service call in the block.
  const throwAt = handler.indexOf('throw new AuthException');
  const serviceCalls = [
    'signInUpService.',
    'authService.',
    'userService.',
    'emailVerificationService.',
  ]
    .map((needle) => handler.indexOf(needle))
    .filter((at) => at !== -1);
  assert.ok(throwAt !== -1, 'signUp block throws AuthException');
  for (const at of serviceCalls) {
    assert.ok(at === -1 || throwAt < at, 'SIGNUP_DISABLED throw precedes any service write path');
  }
});

test('anonymous signUpInWorkspace without invite is denied (fail-closed)', () => {
  const svc = readFileSync(
    join(SRC, 'engine', 'core-modules', 'auth', 'services', 'auth.service.ts'),
    'utf8',
  );
  // No-invite + existing workspace + new user -> FORBIDDEN_EXCEPTION.
  assert.ok(
    svc.includes('User does not have access to this workspace'),
    'anonymous no-invite signup denied with a clear error',
  );
  // Bare public-link without a personal invite -> personal-invite error,
  // enforced unless explicitly relaxed to 'false' (fail-closed default).
  assert.ok(
    svc.includes('A personal invitation is required to join this workspace'),
    'public-link-only signup requires a personal invitation',
  );
  assert.ok(
    svc.includes('MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP') && svc.includes("'false'"),
    'gate is fail-closed: only literal false disables it',
  );
});
