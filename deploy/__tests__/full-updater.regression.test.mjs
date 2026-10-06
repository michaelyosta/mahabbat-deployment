// Stage D regression: full updater contract (F03/F11/F12).
// Static + fixture-driven, no docker/registry/live install:
//   F03 full-kit apply .. apply covers host/locks/inner/images/metadata/reconcile/verify, not images-only
//   F11 check→apply .... check records a pinned target; apply re-asserts it (no alias swap)
//   F12 rollback/resume  every apply stage journals state; rollback covers tags+restart and names restore
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

const ROOT = join(import.meta.dirname, '..', '..');
const UPDATE = readFileSync(join(ROOT, 'scripts', 'mahabbat-update.ps1'), 'utf8');

test('F03: apply updates the full kit, not images alone', () => {
  for (const stage of [
    'backup-gate',
    'locks',
    'inner-checkout',
    'snapshots',
    'metadata-plan',
    'metadata-apply',
    'reconcile',
    'verify',
  ]) {
    assert.ok(UPDATE.includes(`'${stage}'`), `apply must journal stage ${stage}`);
  }
  assert.ok(UPDATE.includes('mahabbat-metadata.ps1'), 'apply must run metadata plan/apply');
  assert.ok(UPDATE.includes('Invoke-MahabbatDamagedTotalsReconcile'), 'apply must reconcile damaged totals');
  assert.ok(!UPDATE.includes('seed-venue'), 'apply must never seed over user data');
  assert.ok(UPDATE.includes('PIN'), 'reconcile must document PIN/price/owner preservation');
});

test('F11: check pins the target; apply re-asserts it before touching runtime', () => {
  assert.ok(UPDATE.includes('Get-MahabbatUpdatePinnedTarget'), 'check must resolve a pinned target');
  assert.ok(UPDATE.includes('TargetDigest'), 'pinned digest must flow check→apply');
  assert.ok(UPDATE.includes('PINNED_TARGET_FILE') || UPDATE.includes('pinnedTargets'), 'check must expose the pinned record');
  assert.ok(UPDATE.includes('target moved since check') || UPDATE.includes('изменилась между check и apply'), 'apply must refuse on alias drift');
  const gatePos = UPDATE.indexOf('Get-MahabbatValidatedBackupGate');
  const pullPos = UPDATE.indexOf("Invoke-MahabbatCompose @('pull')");
  assert.ok(gatePos !== -1 && pullPos !== -1 && gatePos < pullPos, 'backup gate must precede pull');
});

test('F12: every apply failure has a journaled rollback/resume path', () => {
  assert.ok(UPDATE.includes('Write-MahabbatUpdateJournalEntry'), 'stages must journal');
  assert.ok(UPDATE.includes('Invoke-MahabbatUpdateRollback'), 'apply must call rollback on failure');
  assert.ok(UPDATE.includes('mahabbat-restore.ps1'), 'rollback must name the data-restore path when data was touched');
  assert.ok(UPDATE.includes(':previous'), 'image rollback must use snapshots');
  assert.ok(UPDATE.includes('resume') || UPDATE.includes('Resume') || UPDATE.includes('повторите apply'), 'resume must be documented');
  assert.ok(UPDATE.includes('maintenance') || UPDATE.includes('MAINTENANCE'), 'maintenance window must bracket the mutation');
});

test('post-update verify covers versions/images/logic-functions/parity/health/invariants', () => {
  assert.ok(UPDATE.includes('Get-MahabbatUpdateVerifyReport'), 'verify report must exist');
  for (const probe of ['inner', 'images', 'logic-function', 'health']) {
    assert.ok(UPDATE.toLowerCase().includes(probe), `verify must probe ${probe}`);
  }
  const api = readFileSync(join(ROOT, 'installer', 'app', 'setup-api.mjs'), 'utf8');
  assert.ok(api.includes('/api/update-verify'), 'wizard API must expose update-verify');
  const wizard = readFileSync(join(ROOT, 'installer', 'app', 'wizard.html'), 'utf8');
  assert.ok(wizard.includes('update-verify'), 'wizard must call update-verify after apply');
  assert.ok(wizard.includes('Mahabbat'), 'wizard must show the Mahabbat version, not Twenty');
});
