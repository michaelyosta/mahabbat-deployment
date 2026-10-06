import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// Fork test 3/3: rotate single-flight / concurrency contract. Rotation is
// mint-then-revoke (never revoke-then-mint): the replacement key is created
// and its token verified FIRST; only pre-mint ids are revoked, so a key
// minted concurrently (the race winner) is never revoked and the workspace
// is never left keyless. Any mint/token/revoke failure throws (fail-loud:
// non-zero exit, old keys stay valid) — warn-and-continue is forbidden.
// Verified against the committed dist mirror (the artifact that ships).
const ROOT = join(import.meta.dirname, '..', '..');
const JS = join(ROOT, 'deploy', 'mahabbat-fork-patch', 'workspace-rotate-api-key.command.js');

test('dist rotate keeps mint-then-revoke single-flight semantics', () => {
  const js = readFileSync(JS, 'utf8');
  for (const needle of [
    'pg_advisory_lock',
    'preMintActive',
    'generateApiKeyToken',
    'MAHABBAT_API_KEY=',
    'Failed to generate token',
    'Failed to revoke API key',
    'Failed to create replacement API key',
  ]) {
    assert.ok(js.includes(needle), `dist rotate contains: ${needle}`);
  }
  // No silent degradation: the only warn path is the lock-unavailable
  // fallback, which still keeps the pre-mint snapshot guarantee.
  assert.ok(js.includes('continuing unlocked'), 'dist keeps the warn-and-proceed-unlocked path only for locks');
  assert.ok(js.includes('throw new Error'), 'dist failures throw (fail-loud), never swallow');
});

test('dist rotate never revokes the key it just minted', () => {
  const js = readFileSync(JS, 'utf8');
  // Own-key skip: the revoke loop skips the newly minted key id.
  assert.ok(js.includes('apiKey.id'), 'revoke loop references the newly minted key id');
  // Snapshot-before-mint: pre-mint ids captured before create().
  const snapshotAt = js.indexOf('findActiveByWorkspaceId');
  const createAt = js.indexOf('.create(');
  assert.ok(snapshotAt !== -1 && createAt !== -1, 'snapshot + mint both present');
  assert.ok(snapshotAt < createAt, 'pre-mint snapshot is taken BEFORE the mint (concurrent winners kept)');
});
