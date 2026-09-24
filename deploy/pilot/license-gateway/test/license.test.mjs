import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { canonicalJson, evaluateLicense } from '../src/license.mjs';

const keys = generateKeyPairSync('ed25519');
const installationId = '9b2d9e97-49cf-4e40-8a62-1db0b0f01bb9';
const fingerprint = 'a'.repeat(64);

const signedDocument = (overrides = {}) => {
  const payload = {
    schema_version: 1,
    product: 'Mahabbat',
    customer: 'Mahabbat Pilot Test',
    type: 'pilot',
    installation_id: installationId,
    machine_fingerprint: fingerprint,
    issued_at: '2026-09-01T00:00:00.000Z',
    expires_at: '2026-10-01T00:00:00.000Z',
    features: ['crm', 'pos', 'inventory', 'printing'],
    ...overrides,
  };
  return {
    payload,
    signature: sign(null, Buffer.from(canonicalJson(payload)), keys.privateKey).toString('base64'),
  };
};

const createFixture = async (t, { document = signedDocument(), install = {} } = {}) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'mahabbat-license-test-'));
  const licenseDir = path.join(root, 'license');
  const configDir = path.join(root, 'config');
  const stateDir = path.join(root, 'state');
  await Promise.all([mkdir(licenseDir), mkdir(configDir), mkdir(stateDir)]);
  const paths = {
    licensePath: path.join(licenseDir, 'license.json'),
    publicKeyPath: path.join(licenseDir, 'public-key.pem'),
    installationPath: path.join(configDir, 'installation.json'),
    statePath: path.join(stateDir, 'last-seen.json'),
  };
  await writeFile(paths.publicKeyPath, keys.publicKey.export({ type: 'spki', format: 'pem' }));
  await writeFile(paths.installationPath, JSON.stringify({
    installation_id: installationId,
    machine_fingerprint: fingerprint,
    ...install,
  }));
  if (document) await writeFile(paths.licensePath, JSON.stringify(document));
  t.after(() => rm(root, { recursive: true, force: true }));
  return paths;
};

test('accepts a valid Ed25519 license bound to this installation and machine', async (t) => {
  const paths = await createFixture(t);
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T00:00:00.000Z') });
  assert.equal(state.active, true);
  assert.equal(state.status, 'ACTIVE');
  assert.equal(state.customer, 'Mahabbat Pilot Test');
  assert.equal(state.expiresAt, '2026-10-01T00:00:00.000Z');
});

test('restricts a missing or tampered license', async (t) => {
  const missing = await createFixture(t, { document: null });
  assert.equal((await evaluateLicense({ ...missing, now: Date.parse('2026-09-24T00:00:00.000Z') })).status, 'NO_LICENSE');

  const tamperedDoc = signedDocument();
  tamperedDoc.payload.customer = 'Tampered';
  const tampered = await createFixture(t, { document: tamperedDoc });
  assert.equal((await evaluateLicense({ ...tampered, now: Date.parse('2026-09-24T00:00:00.000Z') })).status, 'INVALID_LICENSE_SIGNATURE');
});

test('rejects a license bound to another installation', async (t) => {
  const paths = await createFixture(t, { document: signedDocument({ installation_id: '11111111-1111-4111-8111-111111111111' }) });
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T00:00:00.000Z') });
  assert.equal(state.status, 'INSTALLATION_MISMATCH');
});

test('rejects a license bound to another machine fingerprint', async (t) => {
  const paths = await createFixture(t, { document: signedDocument({ machine_fingerprint: 'b'.repeat(64) }) });
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T00:00:00.000Z') });
  assert.equal(state.status, 'MACHINE_MISMATCH');
});

test('expired license remains verifiable but is inactive', async (t) => {
  const paths = await createFixture(t);
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-10-01T00:00:00.000Z') });
  assert.equal(state.active, false);
  assert.equal(state.status, 'LICENSE_EXPIRED');
});

test('persists the last seen time and detects a material clock rollback', async (t) => {
  const paths = await createFixture(t, { document: null });
  await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T12:00:00.000Z') });
  const persisted = JSON.parse(await readFile(paths.statePath, 'utf8'));
  assert.equal(persisted.last_seen_utc, '2026-09-24T12:00:00.000Z');
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T11:00:00.000Z') });
  assert.equal(state.status, 'CLOCK_ROLLBACK');
});

test('fails closed when anti-rollback state belongs to another installation', async (t) => {
  const paths = await createFixture(t);
  await writeFile(paths.statePath, JSON.stringify({ version: 1, installation_id: '11111111-1111-4111-8111-111111111111', last_seen_utc: '2026-09-24T12:00:00.000Z' }));
  const state = await evaluateLicense({ ...paths, now: Date.parse('2026-09-24T12:01:00.000Z') });
  assert.equal(state.status, 'CLOCK_STATE_MISMATCH');
});
