#!/usr/bin/env node
import { createHmac, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const argument = (name, fallback = '') => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? String(process.argv[index + 1] ?? fallback) : fallback;
};

const packageDir = path.resolve(argument('--package-dir', path.dirname(fileURLToPath(import.meta.url))));
const innerDir = path.resolve(argument('--inner-dir', path.resolve(packageDir, '..', '..', 'mahabbat-app')));
const secret = 'mahabbat-print-bridge-self-test-secret';
const printResolverId = 'd4f3e7fb-8c05-4e26-8d94-5a0b1f3e7d44';
const posResolverId = '54be0dfa-2fd6-45bc-be93-6ba4c64a21d9';

const listen = async (server) => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server.address().port;
};

const close = async (server) => {
  if (!server.listening) return;
  server.close();
  await once(server, 'close');
};

const freePort = async () => {
  const probe = createServer();
  const port = await listen(probe);
  await close(probe);
  return port;
};

const bodyOf = async (req) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  try { return text ? JSON.parse(text) : null; } catch { return null; }
};

const respond = (res, status, body) => {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
};

const waitFor = async (predicate, timeoutMs = 12_000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (await predicate()) return;
    } catch {
      // The service may still be binding its local port.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('self-test timed out');
};

const fetchJson = async (url, options = {}) => {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(5_000) });
  const body = await response.json().catch(() => ({}));
  return { response, body };
};

const simulator = await import(pathToFileURL(path.join(innerDir, 'pos-standalone', 'server', 'printer-simulator.mjs')));
const printer = simulator.createPrinterSimulator({ host: '127.0.0.1', port: 0, mode: 'success' });
const printerAddress = await printer.start();
const reports = [];
let claimSent = false;

const upstream = createServer(async (req, res) => {
  const body = await bodyOf(req);
  const signature = req.headers['x-mahabbat-signature'];
  const expected = createHmac('sha256', secret).update(JSON.stringify(body), 'utf8').digest('hex');
  if (signature !== expected) { respond(res, 403, { code: 'INVALID_SIGNATURE' }); return; }
  const resolverId = req.url?.split('/').pop();
  if (resolverId === printResolverId) {
    if (body?.command === 'health') { respond(res, 200, { status: 'ok' }); return; }
    if (body?.command === 'claim') {
      if (!claimSent) {
        claimSent = true;
        respond(res, 200, { jobs: [{
          id: randomUUID(),
          claimToken: 'self-test-claim',
          documentType: 'TEST_PRINT',
          payloadSnapshot: JSON.stringify({ printerLabel: 'Тестовый принтер', createdAt: new Date().toISOString() }),
          printer: { id: randomUUID(), connectionType: 'ETHERNET_RAW_TCP', host: printerAddress.address, port: printerAddress.port, isActive: true, paperWidth: '80', encodingProfile: 'UTF8', cutSupport: false },
        }] });
      } else respond(res, 200, { jobs: [] });
      return;
    }
    if (body?.command === 'report') { reports.push(body); respond(res, 200, { jobId: body.jobId, status: body.outcome }); return; }
    if (body?.command === 'printerStatus') { respond(res, 200, { printerDeviceId: body.printerDeviceId, status: body.outcome }); return; }
    respond(res, 400, { code: 'INVALID_COMMAND' });
    return;
  }
  if (resolverId === posResolverId) {
    if (body?.command === 'upsertPrinterDevice') { respond(res, 201, { printerDeviceId: randomUUID(), status: 'CONFIGURED' }); return; }
    if (body?.command === 'testPrinterDevice') { respond(res, 201, { printJobId: randomUUID(), status: 'QUEUED', documentType: 'TEST_PRINT' }); return; }
    if (body?.command === 'upsertProductionStation') { respond(res, 200, { productionStationId: body.payload?.productionStationId, status: 'CONFIGURED' }); return; }
  }
  respond(res, 404, { code: 'NOT_FOUND' });
});
const upstreamPort = await listen(upstream);
const uiPort = await freePort();
const gatewayPort = await freePort();
const tempRoot = path.join(os.tmpdir(), `mahabbat-print-bridge-self-test-${randomUUID()}`);
await mkdir(path.join(tempRoot, 'config'), { recursive: true });
const configPath = path.join(tempRoot, 'config', 'bridge.env');
const statePath = path.join(tempRoot, 'bridge-state.json');
const logPath = path.join(tempRoot, 'bridge.log');
const stationsPath = path.join(tempRoot, 'stations.json');
const devicesPath = path.join(tempRoot, 'devices.json');
await writeFile(configPath, [
  `TWENTY_API_URL=http://127.0.0.1:${upstreamPort}`,
  'PRINT_GATEWAY_MODE=REMOTE',
  `MAHABBAT_INTERNAL_ROUTE_SECRET=${secret}`,
  'PRINT_GATEWAY_HOST=127.0.0.1',
  `PRINT_GATEWAY_PORT=${gatewayPort}`,
  'PRINT_GATEWAY_ID=bridge-self-test',
  'PRINT_GATEWAY_POLL_MS=500',
  'PRINT_GATEWAY_CONNECT_TIMEOUT_MS=500',
  'PRINT_GATEWAY_AUTO_RETRY_LIMIT=0',
  `MAHABBAT_BRIDGE_PORT=${uiPort}`,
].join('\n'), 'utf8');
await writeFile(stationsPath, '[]\n', 'utf8');
await writeFile(devicesPath, '[]\n', 'utf8');

const nodePath = path.join(packageDir, 'runtime', 'node.exe');
const appPath = path.join(packageDir, 'bridge-app.mjs');
const child = spawn(nodePath, [appPath, '--no-browser'], {
  cwd: packageDir,
  windowsHide: true,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: {
    ...process.env,
    MAHABBAT_BRIDGE_CONFIG: configPath,
    MAHABBAT_BRIDGE_STATE: statePath,
    MAHABBAT_BRIDGE_LOG: logPath,
    MAHABBAT_BRIDGE_STATIONS_FILE: stationsPath,
    MAHABBAT_BRIDGE_DEVICES_FILE: devicesPath,
    MAHABBAT_BRIDGE_NO_BROWSER: '1',
  },
});
let output = '';
child.stdout.setEncoding('utf8');
child.stderr.setEncoding('utf8');
child.stdout.on('data', (chunk) => { output += chunk; });
child.stderr.on('data', (chunk) => { output += chunk; });

try {
  const uiBase = `http://127.0.0.1:${uiPort}`;
  await waitFor(async () => (await fetchJson(`${uiBase}/api/health`)).response.ok);
  let status;
  await waitFor(async () => {
    status = await fetchJson(`${uiBase}/api/status`);
    return status.response.ok
      && status.body.server?.state === 'CONNECTED'
      && status.body.gateway?.state === 'RUNNING';
  });
  const page = await fetch(`${uiBase}/`);
  const pageText = await page.text();
  if (!page.ok || !pageText.includes('Mahabbat Print Bridge') || !pageText.includes('Тестовая печать') || !pageText.includes('Сетевой принтер')) throw new Error('status UI page is incomplete');
  await waitFor(() => reports.some((report) => report.outcome === 'SENT'));
  if (!printer.captured.length) throw new Error('simulator did not receive a rendered test document');
  const printers = await fetchJson(`${uiBase}/api/printers`);
  if (!printers.response.ok || !Array.isArray(printers.body.printers)) throw new Error('printer discovery endpoint failed');
  if (printers.body.printers[0]) {
    const selected = printers.body.printers[0];
    const configured = await fetchJson(`${uiBase}/api/configure`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ systemQueueName: selected.systemQueueName, label: 'Тестовый принтер', paperWidth: '80', encodingProfile: 'CP866' }) });
    if (!configured.response.ok || !configured.body.device?.id) throw new Error('printer binding endpoint failed');
    const test = await fetchJson(`${uiBase}/api/test-print`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ deviceId: configured.body.device.id }) });
    if (!test.response.ok || !test.body.message) throw new Error('test print command endpoint failed');
  }
  const ethernetConfigured = await fetchJson(`${uiBase}/api/configure`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ connectionType: 'ETHERNET_RAW_TCP', host: printerAddress.address, port: printerAddress.port, label: 'Тестовый сетевой принтер', paperWidth: '80', encodingProfile: 'UTF8' }) });
  if (!ethernetConfigured.response.ok || !ethernetConfigured.body.device?.id || ethernetConfigured.body.device.connectionType !== 'ETHERNET_RAW_TCP') throw new Error('ethernet printer binding endpoint failed');
  const ethernetTest = await fetchJson(`${uiBase}/api/test-print`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ deviceId: ethernetConfigured.body.device.id }) });
  if (!ethernetTest.response.ok || !ethernetTest.body.message) throw new Error('ethernet test print command endpoint failed');
  await fetchJson(`${uiBase}/api/stop`, { method: 'POST' });
  await waitFor(() => child.exitCode !== null, 5_000);
  console.log('PRINT_BRIDGE_PACKAGE_SELF_TEST PASS');
} catch (error) {
  const details = output.trim().slice(-4000);
  console.error(`PRINT_BRIDGE_PACKAGE_SELF_TEST FAIL: ${error?.message ?? error}${details ? `\n${details}` : ''}`);
  throw error;
} finally {
  if (child.exitCode === null) child.kill();
  await close(upstream);
  await printer.stop();
  await rm(tempRoot, { recursive: true, force: true });
}

function pathToFileURL(filePath) {
  const normalized = path.resolve(filePath).replace(/\\/g, '/');
  return new URL(`file:///${encodeURI(normalized)}`);
}
