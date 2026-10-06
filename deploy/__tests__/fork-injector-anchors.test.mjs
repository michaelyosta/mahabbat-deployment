import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// Fork test 1/3: injector-anchor presence. Every fail-closed anchor the
// dist injector (deploy/mahabbat-fork-patch/inject-fork-patch.mjs) asserts
// must exist in the TS sources it mirrors, or the docker build breaks.
const ROOT = join(import.meta.dirname, '..', '..');
const SRC = join(ROOT, 'mahabbat-twenty', 'packages', 'twenty-server', 'src');
const read = (rel) => readFileSync(join(SRC, rel), 'utf8');

test('fork injector anchors exist in TS sources', () => {
  const mod = read('database/commands/database-command.module.ts');
  assert.ok(
    mod.includes('DataSeedWorkspaceCommand'),
    'module require anchor: DataSeedWorkspaceCommand import',
  );
  assert.ok(
    mod.includes('BootstrapVenueCommand'),
    'module provider anchor: BootstrapVenueCommand registered',
  );

  const key = read('engine/core-modules/api-key/commands/generate-api-key.command.ts');
  assert.ok(
    key.includes('This command is only available in development or test environments'),
    'api-key guard anchor: dev/test-only error text',
  );
  assert.ok(
    key.includes('parseAllowProduction'),
    'api-key option anchor: --allow-production registered',
  );

  const resolver = read('engine/core-modules/auth/auth.resolver.ts');
  assert.ok(
    resolver.includes('async signUp('),
    'auth-resolver signup anchor: signUp method',
  );
  assert.ok(
    resolver.includes('SIGNUP_DISABLED'),
    'signup disable anchor: SIGNUP_DISABLED thrown',
  );

  const svc = read('engine/core-modules/auth/services/auth.service.ts');
  assert.ok(
    svc.includes('isPublicInviteLinkEnabled'),
    'auth-service gate anchor: public-link field check',
  );
  assert.ok(
    svc.includes('A personal invitation is required to join this workspace'),
    'personal-invite gate anchor: fail-closed error text',
  );
  assert.ok(
    svc.includes('mahabbatPasswordSignupRequiresPersonalInvite'),
    'gate helpers anchor: fail-closed flag readers',
  );
  assert.ok(
    svc.includes('MAHABBAT_SSO_SIGNUP_INVITE_MODE'),
    'sso gate anchor: personal-or-public escape hatch',
  );

  const entity = read('engine/core-modules/workspace/workspace.entity.ts');
  assert.ok(
    entity.includes('isPublicInviteLinkEnabled'),
    'workspace-entity field anchor: isPublicInviteLinkEnabled column',
  );

  const rotate = read('engine/core-modules/api-key/commands/rotate-api-key.command.ts');
  assert.ok(
    rotate.includes('workspace:rotate-api-key'),
    'rotate command anchor: command name registered',
  );
  assert.ok(
    rotate.includes('pg_advisory_lock'),
    'rotate single-flight anchor: advisory lock held across mint',
  );
});
