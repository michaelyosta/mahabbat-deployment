import http from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { evaluateLicense, publicLicenseStatus } from './license.mjs';
import { describeRestrictedMessage, isRestrictedRequestAllowed } from './policy.mjs';

const defaultLicensePaths = {
  licensePath: process.env.MAHABBAT_LICENSE_FILE ?? '/license/license.json',
  installationPath: process.env.MAHABBAT_INSTALLATION_FILE ?? '/config/installation.json',
  publicKeyPath: process.env.MAHABBAT_LICENSE_PUBLIC_KEY ?? '/license/public-key.pem',
  statePath: process.env.MAHABBAT_LICENSE_STATE_FILE ?? '/state/last-seen.json',
};

const defaultConfig = {
  crm: { host: process.env.MAHABBAT_CRM_UPSTREAM ?? 'http://server:3000', port: Number(process.env.MAHABBAT_CRM_PORT ?? 3000) },
  pos: { host: process.env.MAHABBAT_POS_UPSTREAM ?? 'http://pos-gateway:3100', port: Number(process.env.MAHABBAT_POS_PORT ?? 3100) },
  statusPort: Number(process.env.MAHABBAT_LICENSE_STATUS_PORT ?? 3199),
};

const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer',
  'transfer-encoding', 'upgrade',
]);

const safeHeaders = (headers, host) => {
  const result = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP.has(name.toLowerCase()) && value !== undefined) result[name] = value;
  }
  result.host = host;
  result['x-forwarded-host'] ??= headers.host;
  return result;
};

const sendJson = (res, code, body, extra = {}) => {
  const bytes = Buffer.from(JSON.stringify(body));
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': bytes.length,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extra,
  });
  res.end(bytes);
};

const readBoundedBody = async (req, limit = 2 * 1024 * 1024) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw Object.assign(new Error('Request body exceeds limit'), { code: 'BODY_TOO_LARGE' });
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
};

const proxy = (req, res, upstream, body) => {
  const target = new URL(req.url, upstream);
  const headers = safeHeaders(req.headers, target.host);
  if (body) {
    headers['content-length'] = body.length;
    delete headers['transfer-encoding'];
  }
  const upstreamRequest = http.request({
    hostname: target.hostname,
    port: target.port || 80,
    path: `${target.pathname}${target.search}`,
    method: req.method,
    headers,
  }, (upstreamResponse) => {
    const responseHeaders = {};
    for (const [name, value] of Object.entries(upstreamResponse.headers)) {
      if (!HOP_BY_HOP.has(name.toLowerCase()) && value !== undefined) responseHeaders[name] = value;
    }
    res.writeHead(upstreamResponse.statusCode ?? 502, responseHeaders);
    upstreamResponse.pipe(res);
  });
  upstreamRequest.on('error', (error) => {
    console.error(JSON.stringify({ event: 'upstream_error', code: error.code ?? 'UPSTREAM_ERROR' }));
    if (!res.headersSent) sendJson(res, 503, { message: 'Mahabbat временно недоступен.' });
    else res.destroy();
  });
  if (body) upstreamRequest.end(body);
  else req.pipe(upstreamRequest);
};

const restrictedResponse = (res, state, surface) => {
  const message = describeRestrictedMessage(state);
  const body = surface === 'crm'
    ? { errors: [{ message, extensions: { code: 'MAHABBAT_LICENSE_RESTRICTED', licenseState: state.status } }] }
    : { code: 'MAHABBAT_LICENSE_RESTRICTED', licenseState: state.status, message };
  sendJson(res, 423, body, { 'x-mahabbat-license-state': state.status ?? state.reason });
};

const handleSurface = async (surface, req, res, options) => {
  const upstream = options.config[surface].host;
  const url = new URL(req.url, 'http://localhost');
  let state;
  try {
    state = await options.getState();
  } catch {
    state = { active: false, status: 'LICENSE_CHECK_FAILED', reason: 'LICENSE_CHECK_FAILED' };
  }

  if (!state.active) {
    let body;
    if (req.method.toUpperCase() !== 'GET' && req.method.toUpperCase() !== 'HEAD' && req.method.toUpperCase() !== 'OPTIONS') {
      try {
        body = await readBoundedBody(req);
      } catch (error) {
        const tooLarge = error.code === 'BODY_TOO_LARGE';
        sendJson(res, tooLarge ? 413 : 400, { code: tooLarge ? 'REQUEST_TOO_LARGE' : 'INVALID_REQUEST' });
        return;
      }
    }
    const allowed = isRestrictedRequestAllowed({
      method: req.method,
      pathname: url.pathname,
      searchParams: url.searchParams,
      body,
      surface,
    });
    if (!allowed) {
      restrictedResponse(res, state, surface);
      console.log(JSON.stringify({ event: 'restricted_request', surface, method: req.method, path: url.pathname, status: 423, state: state.status ?? state.reason }));
      return;
    }
    proxy(req, res, upstream, body);
    return;
  }

  proxy(req, res, upstream);
};

const createSurfaceServer = (surface, options) => http.createServer((req, res) => {
  handleSurface(surface, req, res, options).catch(() => {
    if (!res.headersSent) sendJson(res, 500, { message: 'Внутренняя ошибка Mahabbat.' });
    else res.destroy();
  });
});

const handleUpgrade = async (surface, req, clientSocket, head, options) => {
  let state;
  try { state = await options.getState(); } catch { state = { active: false, status: 'LICENSE_CHECK_FAILED' }; }
  if (!state.active) {
    clientSocket.end('HTTP/1.1 423 Locked\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  const target = new URL(req.url, options.config[surface].host);
  const upstreamRequest = http.request({
    hostname: target.hostname,
    port: target.port || 80,
    path: `${target.pathname}${target.search}`,
    headers: req.headers,
  });
  upstreamRequest.on('upgrade', (response, upstreamSocket, upstreamHead) => {
    const statusLine = `HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\n`;
    const headers = Object.entries(response.headers).map(([name, value]) => `${name}: ${Array.isArray(value) ? value.join(', ') : value}`).join('\r\n');
    clientSocket.write(`${statusLine}${headers}\r\n\r\n`);
    if (head.length) upstreamSocket.write(head);
    if (upstreamHead.length) clientSocket.write(upstreamHead);
    clientSocket.pipe(upstreamSocket).pipe(clientSocket);
  });
  upstreamRequest.on('response', (response) => {
    clientSocket.end(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\nConnection: close\r\n\r\n`);
  });
  upstreamRequest.on('error', () => clientSocket.destroy());
  upstreamRequest.end();
};

const listen = (server, port, host) => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(port, host, () => {
    server.removeListener('error', reject);
    resolve(server.address());
  });
});

export async function createGatewayServer({
  licensePaths = defaultLicensePaths,
  config = defaultConfig,
  host = '0.0.0.0',
} = {}) {
  const options = { licensePaths, config, getState: () => evaluateLicense(licensePaths) };
  const crmServer = createSurfaceServer('crm', options);
  const posServer = createSurfaceServer('pos', options);
  crmServer.on('upgrade', (req, socket, head) => handleUpgrade('crm', req, socket, head, options));
  posServer.on('upgrade', (req, socket, head) => handleUpgrade('pos', req, socket, head, options));
  const statusServer = http.createServer(async (req, res) => {
    if (req.method !== 'GET' || new URL(req.url, 'http://localhost').pathname !== '/status') {
      sendJson(res, 404, { message: 'Not found' });
      return;
    }
    try {
      const state = await options.getState();
      sendJson(res, 200, publicLicenseStatus(state));
    } catch {
      sendJson(res, 200, { status: 'LICENSE_CHECK_FAILED', active: false });
    }
  });

  await Promise.all([
    listen(crmServer, config.crm.port, host),
    listen(posServer, config.pos.port, host),
    listen(statusServer, config.statusPort, host),
  ]);

  return {
    crmServer,
    posServer,
    statusServer,
    close: async () => Promise.all([
      new Promise((resolve) => crmServer.close(resolve)),
      new Promise((resolve) => posServer.close(resolve)),
      new Promise((resolve) => statusServer.close(resolve)),
    ]),
  };
}

export async function startGateway() {
  const gateway = await createGatewayServer();
  console.log(JSON.stringify({ event: 'proxy_ready', surface: 'crm', port: gateway.crmServer.address().port }));
  console.log(JSON.stringify({ event: 'proxy_ready', surface: 'pos', port: gateway.posServer.address().port }));
  console.log(JSON.stringify({ event: 'license_status_ready', port: gateway.statusServer.address().port }));
  const close = () => gateway.close().catch(() => process.exitCode = 1);
  process.on('SIGTERM', close);
  process.on('SIGINT', close);
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  startGateway().catch(() => {
    console.error(JSON.stringify({ event: 'license_gateway_start_failed' }));
    process.exitCode = 1;
  });
}
