import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { evaluateLicense } from '../../deploy/pilot/license-gateway/src/license.mjs';

const cli = path.join(import.meta.dirname, 'license-cli.mjs');
const runCli = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', windowsHide: true });

test('generator creates a verifiable 30-day machine-bound license and refuses overwrite', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'mahabbat-license-generator-test-'));
  const privateKey = path.join(root, 'private.pem');
  const publicKey = path.join(root, 'public.pem');
  const licensePath = path.join(root, 'license.json');
  const installationPath = path.join(root, 'installation.json');
  const statePath = path.join(root, 'state', 'last-seen.json');
  const fingerprint = 'c'.repeat(64);
  const installationId = 'c3a430d0-283c-4d9d-9f43-d83e36728208';
  const activationRequest = path.join(root, 'activation-request.json');
  await mkdir(path.dirname(installationPath), { recursive: true });
  await writeFile(activationRequest, JSON.stringify({
    product: 'Mahabbat',
    installation_id: installationId,
    machine_fingerprint: fingerprint,
  }));
  await writeFile(installationPath, JSON.stringify({
    installation_id: installationId,
    machine_fingerprint: fingerprint,
  }));
  t.after(() => rm(root, { recursive: true, force: true }));

  const init = runCli('init', '--private-key', privateKey, '--public-key', publicKey);
  assert.equal(init.status, 0, init.stderr);
  const issue = runCli('issue', '--private-key', privateKey, '--activation-request', activationRequest, '--customer', 'Local Test', '--days', '30', '--output', licensePath);
  assert.equal(issue.status, 0, issue.stderr);

  const signed = JSON.parse(await readFile(licensePath, 'utf8'));
  assert.equal(signed.payload.duration_days, 30);
  assert.equal(signed.payload.installation_id, installationId);
  assert.equal(signed.payload.machine_fingerprint, fingerprint);
  const issued = Date.parse(signed.payload.issued_at);
  const expires = Date.parse(signed.payload.expires_at);
  assert.equal(expires - issued, 30 * 24 * 60 * 60 * 1000);

  const active = await evaluateLicense({
    licensePath,
    installationPath,
    publicKeyPath: publicKey,
    statePath,
    now: issued + 1,
  });
  assert.equal(active.active, true);

  const duplicate = runCli('issue', '--private-key', privateKey, '--activation-request', activationRequest, '--customer', 'Local Test', '--days', '30', '--output', licensePath);
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr, /already exists|EEXIST/i);
});
