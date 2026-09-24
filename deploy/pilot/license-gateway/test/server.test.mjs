import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { canonicalJson } from '../src/license.mjs';
import { createGatewayServer } from '../src/server.mjs';

const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address())));
const close = (server) => new Promise((resolve) => server.close(resolve));

test('HTTP gateway enforces expired read-only policy while retaining login and reads', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'mahabbat-gateway-test-'));
  const licenseDir = path.join(root, 'license');
  const configDir = path.join(root, 'config');
  const stateDir = path.join(root, 'state');
  await Promise.all([mkdir(licenseDir), mkdir(configDir), mkdir(stateDir)]);
  const installationId = '9b2d9e97-49cf-4e40-8a62-1db0b0f01bb9';
  const machineFingerprint = createHash('sha256').update('gateway-test-host').digest('hex');
  const keys = generateKeyPairSync('ed25519');
  await writeFile(path.join(configDir, 'installation.json'), JSON.stringify({ installation_id: installationId, machine_fingerprint: machineFingerprint }));
  await writeFile(path.join(licenseDir, 'public-key.pem'), keys.publicKey.export({ type: 'spki', format: 'pem' }));
  t.after(() => rm(root, { recursive: true, force: true }));

  const received = [];
  const upstream = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    received.push({ method: req.method, url: req.url, body: Buffer.concat(chunks).toString('utf8') });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ upstream: true }));
  });
  const address = await listen(upstream);
  const origin = `http://127.0.0.1:${address.port}`;
  const gateway = await createGatewayServer({
    host: '127.0.0.1',
    licensePaths: {
      licensePath: path.join(licenseDir, 'license.json'),
      publicKeyPath: path.join(licenseDir, 'public-key.pem'),
      installationPath: path.join(configDir, 'installation.json'),
      statePath: path.join(stateDir, 'last-seen.json'),
    },
    config: {
      crm: { host: origin, port: 0 },
      pos: { host: origin, port: 0 },
      statusPort: 0,
    },
  });
  t.after(async () => {
    await gateway.close();
    await close(upstream);
  });

  const crm = `http://127.0.0.1:${gateway.crmServer.address().port}`;
  const pos = `http://127.0.0.1:${gateway.posServer.address().port}`;
  const query = await fetch(`${crm}/graphql`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'query { people { totalCount } }' }) });
  assert.equal(query.status, 200);
  const blockedCrm = await fetch(`${crm}/graphql`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation { createPerson(input: {}) { id } }' }) });
  assert.equal(blockedCrm.status, 423);
  assert.equal((await blockedCrm.json()).errors[0].extensions.code, 'MAHABBAT_LICENSE_RESTRICTED');
  const login = await fetch(`${crm}/graphql`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'mutation { signIn(login: "owner", password: "private") { tokens { accessToken } } }' }) });
  assert.equal(login.status, 200);
  const posRead = await fetch(`${pos}/api/pos/rest/posOrders`);
  assert.equal(posRead.status, 200);
  const posLogin = await fetch(`${pos}/api/pos/auth`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ pin: 'not-logged' }) });
  assert.equal(posLogin.status, 200);
  const posMutation = await fetch(`${pos}/api/pos/command`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ command: 'openOrder' }) });
  assert.equal(posMutation.status, 423);
  assert.equal(received.filter((request) => request.method === 'POST' && request.url === '/graphql').length, 2);
  assert.equal(received.some((request) => request.url === '/api/pos/command'), false);

  const status = await fetch(`http://127.0.0.1:${gateway.statusServer.address().port}/status`);
  const statusBody = await status.json();
  assert.equal(statusBody.status, 'NO_LICENSE');
  assert.equal(JSON.stringify(statusBody).includes(machineFingerprint), false);
  assert.equal(JSON.stringify(statusBody).includes(installationId), false);
});

test('HTTP gateway transparently forwards commands when a current signed license is installed', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'mahabbat-gateway-active-test-'));
  const licenseDir = path.join(root, 'license');
  const configDir = path.join(root, 'config');
  const stateDir = path.join(root, 'state');
  await Promise.all([mkdir(licenseDir), mkdir(configDir), mkdir(stateDir)]);
  const installationId = '9b2d9e97-49cf-4e40-8a62-1db0b0f01bb9';
  const machineFingerprint = createHash('sha256').update('gateway-active-test-host').digest('hex');
  const keys = generateKeyPairSync('ed25519');
  const payload = {
    schema_version: 1,
    product: 'Mahabbat',
    customer: 'Gateway Test',
    type: 'pilot',
    installation_id: installationId,
    machine_fingerprint: machineFingerprint,
    issued_at: '2026-01-01T00:00:00.000Z',
    expires_at: '2030-01-01T00:00:00.000Z',
    features: ['crm', 'pos', 'inventory', 'printing'],
  };
  await writeFile(path.join(configDir, 'installation.json'), JSON.stringify({ installation_id: installationId, machine_fingerprint: machineFingerprint }));
  await writeFile(path.join(licenseDir, 'public-key.pem'), keys.publicKey.export({ type: 'spki', format: 'pem' }));
  await writeFile(path.join(licenseDir, 'license.json'), JSON.stringify({ payload, signature: sign(null, Buffer.from(canonicalJson(payload)), keys.privateKey).toString('base64') }));
  t.after(() => rm(root, { recursive: true, force: true }));

  let commandSeen = false;
  const upstream = createServer(async (req, res) => {
    if (req.url === '/api/pos/command') commandSeen = true;
    for await (const _chunk of req) { /* consume request body */ }
    res.writeHead(204);
    res.end();
  });
  const address = await listen(upstream);
  const origin = `http://127.0.0.1:${address.port}`;
  const gateway = await createGatewayServer({
    host: '127.0.0.1',
    licensePaths: {
      licensePath: path.join(licenseDir, 'license.json'),
      publicKeyPath: path.join(licenseDir, 'public-key.pem'),
      installationPath: path.join(configDir, 'installation.json'),
      statePath: path.join(stateDir, 'last-seen.json'),
    },
    config: { crm: { host: origin, port: 0 }, pos: { host: origin, port: 0 }, statusPort: 0 },
  });
  t.after(async () => {
    await gateway.close();
    await close(upstream);
  });

  const result = await fetch(`http://127.0.0.1:${gateway.posServer.address().port}/api/pos/command`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ command: 'openOrder' }),
  });
  assert.equal(result.status, 204);
  assert.equal(commandSeen, true);
});
