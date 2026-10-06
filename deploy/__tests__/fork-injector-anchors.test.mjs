import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// Fork test 1/3: injector-anchor presence. Every fail-closed anchor the
// dist injector (deploy/mahabbat-fork-patch/inject-fork-patch.mjs) carries
// is asserted here, plus the committed dist mirrors of both venue commands.
const ROOT = join(import.meta.dirname, '..', '..');
const PATCH = join(ROOT, 'deploy', 'mahabbat-fork-patch');

test('fork injector anchors exist in committed artifacts', () => {
  const injector = readFileSync(join(PATCH, 'inject-fork-patch.mjs'), 'utf8');
  for (const needle of [
    'SIGNUP_DISABLED',
    'async signUp(signUpInput, context)',
    'isPublicInviteLinkEnabled',
    'A personal invitation is required to join this workspace',
    'MAHABBAT_SSO_SIGNUP_INVITE_MODE',
    'MAHABBAT_REQUIRE_PERSONAL_INVITE_FOR_PASSWORD_SIGNUP',
    'workspace:rotate-api-key',
  ]) {
    assert.ok(injector.includes(needle), `injector carries: ${needle}`);
  }

  const rotate = readFileSync(join(PATCH, 'workspace-rotate-api-key.command.js'), 'utf8');
  assert.ok(rotate.includes('workspace:rotate-api-key'), 'rotate command anchor: command name registered');
  assert.ok(rotate.includes('pg_advisory_lock'), 'rotate single-flight anchor: advisory lock held across mint');

  const bootstrap = readFileSync(join(PATCH, 'workspace-bootstrap-venue.command.js'), 'utf8');
  assert.ok(bootstrap.includes('workspace:bootstrap:venue'), 'bootstrap command anchor: command name registered');
  assert.ok(bootstrap.includes('isPublicInviteLinkEnabled'), 'bootstrap link-off anchor: public link forced off');
});

test('dist mirrors declare every require they use (no ReferenceError)', () => {
  for (const file of ['workspace-bootstrap-venue.command.js', 'workspace-rotate-api-key.command.js']) {
    const src = readFileSync(join(PATCH, file), 'utf8');
    const used = [...new Set([...src.matchAll(/([a-z_][a-z0-9_]*_1)\./g)].map((m) => m[1]))];
    for (const v of used) {
      assert.ok(new RegExp('const ' + v + ' = require').test(src), `${file}: ${v} is required`);
    }
  }
});
