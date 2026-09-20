#!/usr/bin/env node
import { createHmac, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { appendFile, mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = process.env.MAHABBAT_BRIDGE_CONFIG ?? path.join(ROOT, 'config', 'bridge.env');

const parseEnv = (source) => {
  const values = {};
  for (const line of source.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (!match || match[1].startsWith('#')) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    values[match[1]] = value;
  }
  return values;
};

let CONFIG = {};
try {
  CONFIG = parseEnv(await readFile(CONFIG_PATH, 'utf8'));
} catch (error) {
  console.error('Mahabbat Print Bridge: private configuration is missing.');
  process.exitCode = 1;
  throw error;
}

const configValue = (name, fallback = '') => process.env[name] ?? CONFIG[name] ?? fallback;
const intValue = (name, fallback, minimum, maximum) => {
  const value = Number(configValue(name, String(fallback)));
  return Number.isInteger(value) && value >= minimum && value <= maximum ? value : fallback;
};

const UI_HOST = '127.0.0.1';
const UI_PORT = intValue('MAHABBAT_BRIDGE_PORT', 3111, 1024, 65535);
const GATEWAY_HOST = '127.0.0.1';
const GATEWAY_PORT = intValue('PRINT_GATEWAY_PORT', 3110, 1024, 65535);
const GATEWAY_URL = `http://${GATEWAY_HOST}:${GATEWAY_PORT}`;
const REMOTE_API_URL = String(configValue('TWENTY_API_URL')).replace(/\/+$/, '');
const INTERNAL_SECRET = configValue('MAHABBAT_INTERNAL_ROUTE_SECRET');
const PRINT_RESOLVER_ID = configValue('PRINT_GATEWAY_RESOLVER_ID', 'd4f3e7fb-8c05-4e26-8d94-5a0b1f3e7d44');
const POS_RESOLVER_ID = configValue('POS_COMMAND_RESOLVER_ID', '54be0dfa-2fd6-45bc-be93-6ba4c64a21d9');
const ACCESS_CLIENT_ID = configValue('CLOUDFLARE_ACCESS_CLIENT_ID');
const ACCESS_CLIENT_SECRET = configValue('CLOUDFLARE_ACCESS_CLIENT_SECRET');
const GATEWAY_ID = configValue('PRINT_GATEWAY_ID', 'restaurant-mahabbat-bridge');
const STATE_PATH = process.env.MAHABBAT_BRIDGE_STATE ?? path.join(ROOT, 'data', 'bridge-state.json');
const LOG_PATH = process.env.MAHABBAT_BRIDGE_LOG ?? path.join(ROOT, 'logs', 'mahabbat-print-bridge.log');
const STATIONS_PATH = process.env.MAHABBAT_BRIDGE_STATIONS_FILE ?? path.join(ROOT, 'config', 'stations.json');
const DEVICES_PATH = process.env.MAHABBAT_BRIDGE_DEVICES_FILE ?? path.join(ROOT, 'config', 'devices.json');
const MAX_LOG_BYTES = 1024 * 1024;

class BridgeError extends Error {
  constructor(code, message, status = 503) {
    super(message);
    this.name = 'BridgeError';
    this.code = code;
    this.status = status;
    this.publicMessage = message;
  }
}

const redact = (value) => {
  const text = String(value ?? '');
  const secrets = [INTERNAL_SECRET, ACCESS_CLIENT_ID, ACCESS_CLIENT_SECRET].filter(Boolean);
  return secrets.reduce((result, secret) => result.split(secret).join('[REDACTED]'), text).slice(0, 512);
};

let logQueue = Promise.resolve();
const log = (level, event, details = {}) => {
  const safeDetails = Object.fromEntries(Object.entries(details).map(([key, value]) => [key, redact(value)]));
  const entry = `${JSON.stringify({ at: new Date().toISOString(), level, event, ...safeDetails })}\n`;
  logQueue = logQueue.then(async () => {
    await mkdir(path.dirname(LOG_PATH), { recursive: true });
    try {
      const current = await stat(LOG_PATH);
      if (current.size >= MAX_LOG_BYTES) {
        await rename(LOG_PATH, `${LOG_PATH}.1`).catch(() => undefined);
      }
    } catch {
      // The log file does not exist yet.
    }
    await appendFile(LOG_PATH, entry, 'utf8');
  }).catch(() => undefined);
};

const readJson = async (filePath, fallback) => {
  try {
    const parsed = JSON.parse(await readFile(filePath, 'utf8'));
    return parsed;
  } catch {
    return fallback;
  }
};

const safeDevice = (device) => ({
  id: String(device?.id ?? ''),
  label: String(device?.label ?? 'Принтер'),
  systemQueueName: String(device?.systemQueueName ?? ''),
  connectionType: String(device?.connectionType ?? 'WINDOWS_SPOOLER'),
  host: String(device?.host ?? ''),
  port: Number.isSafeInteger(Number(device?.port)) ? Number(device.port) : null,
  paperWidth: device?.paperWidth === '58' ? '58' : '80',
  encodingProfile: ['CP866', 'WINDOWS1251', 'UTF8'].includes(device?.encodingProfile) ? device.encodingProfile : 'CP866',
  isPrecheckPrinter: Boolean(device?.isPrecheckPrinter),
  isActive: device?.isActive !== false,
  cutSupport: device?.cutSupport !== false,
  status: String(device?.status ?? 'CONFIGURED'),
});

const configuredDevices = (value) => Array.isArray(value)
  ? value.filter((device) => device && typeof device === 'object' && String(device.id ?? '').trim()).map(safeDevice)
  : [];

const initialStations = await readJson(STATIONS_PATH, []);
const initialDevices = configuredDevices(await readJson(DEVICES_PATH, []));
const stations = Array.isArray(initialStations)
  ? initialStations.filter((station) => station && typeof station === 'object' && String(station.id ?? '').trim()).map((station) => ({
    id: String(station.id),
    label: String(station.label ?? 'Место печати'),
    isActive: station.isActive !== false,
    printerDeviceId: String(station.printerDeviceId ?? '').trim() || null,
  }))
  : [];

const defaultState = {
  activeDeviceId: String(configValue('MAHABBAT_PRINTER_DEVICE_ID')).trim(),
  devices: initialDevices,
  routes: Object.fromEntries(stations.filter((station) => station.printerDeviceId).map((station) => [station.id, station.printerDeviceId])),
  lastJob: null,
};
let state = await readJson(STATE_PATH, defaultState);
if (!state || typeof state !== 'object') state = defaultState;
state.devices = configuredDevices([...(Array.isArray(state.devices) ? state.devices : []), ...initialDevices]);
state.routes = state.routes && typeof state.routes === 'object' ? state.routes : defaultState.routes;
state.activeDeviceId = String(state.activeDeviceId ?? defaultState.activeDeviceId ?? '').trim();
state.lastJob = state.lastJob && typeof state.lastJob === 'object' ? state.lastJob : null;

const saveState = async () => {
  await mkdir(path.dirname(STATE_PATH), { recursive: true });
  const temporary = `${STATE_PATH}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify({
    activeDeviceId: state.activeDeviceId,
    devices: state.devices.map(safeDevice),
    routes: state.routes,
    lastJob: state.lastJob,
  }, null, 2)}\n`, 'utf8');
  await rename(temporary, STATE_PATH);
};

const signBody = (body) => createHmac('sha256', INTERNAL_SECRET).update(JSON.stringify(body), 'utf8').digest('hex');

const jsonResponse = (res, status, body) => {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  });
  res.end(text);
};

const htmlResponse = (res, html) => {
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'content-security-policy': "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
  });
  res.end(html);
};

const parseRequestBody = async (req) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 32 * 1024) throw new BridgeError('REQUEST_TOO_LARGE', 'Запрос слишком большой.', 413);
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new BridgeError('INVALID_REQUEST', 'Не удалось понять запрос.', 400);
  }
};

const errorCodeMessage = (code, status) => {
  if (code === 'PRINTER_NOT_FOUND' || code === 'WINDOWS_PRINTER_NOT_FOUND') return 'Windows не видит выбранный принтер.';
  if (code === 'PRINT_DISCOVERY_UNAVAILABLE' || code === 'WINDOWS_SPOOLER_UNAVAILABLE') return 'Не удалось получить список принтеров Windows.';
  if (code === 'PRINTER_INACTIVE') return 'Принтер отключён в настройках.';
  if (code === 'SYSTEM_PRINTER_NOT_BOUND') return 'Системный принтер не выбран.';
  if (code === 'PRINT_ADMIN_NOT_CONFIGURED') return 'На сервере не настроен администратор печати.';
  if (code === 'CONNECTION_FAILED_BEFORE_SEND' || code === 'ROUTE_UNAVAILABLE') return 'Нет связи с сервером.';
  if (code === 'INVALID_SIGNATURE' || status === 401 || status === 403) return 'Сервер отклонил подключение. Обратитесь к разработчику.';
  if (code === 'PRINT_CONFIG_INVALID' || code === 'INVALID_PAYLOAD') return 'Проверьте выбранный принтер и настройки.';
  if (code === 'PRODUCTION_STATION_NOT_FOUND') return 'Место печати больше не найдено на сервере.';
  if (code === 'PRINTER_DEVICE_NOT_FOUND') return 'Сохранённый принтер больше не найден на сервере.';
  return status >= 500 ? 'Сервер временно недоступен.' : 'Не удалось выполнить действие.';
};

const parseRemoteBody = async (response) => {
  const text = await response.text();
  try { return text ? JSON.parse(text) : {}; } catch { return {}; }
};

const remoteCall = async (resolverId, body) => {
  if (!REMOTE_API_URL || !INTERNAL_SECRET) throw new BridgeError('ROUTE_UNAVAILABLE', 'Нет связи с сервером.');
  const headers = {
    'content-type': 'application/json',
    'x-mahabbat-signature': signBody(body),
  };
  if (ACCESS_CLIENT_ID && ACCESS_CLIENT_SECRET) {
    headers['CF-Access-Client-Id'] = ACCESS_CLIENT_ID;
    headers['CF-Access-Client-Secret'] = ACCESS_CLIENT_SECRET;
  }
  try {
    const response = await fetch(`${REMOTE_API_URL}/webhooks/server/${resolverId}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(12_000),
    });
    const payload = await parseRemoteBody(response);
    if (!response.ok) {
      const code = typeof payload.code === 'string' ? payload.code : `REMOTE_HTTP_${response.status}`;
      log('warn', 'remote_request_failed', { resolver: resolverId, status: response.status, code });
      throw new BridgeError(code, errorCodeMessage(code, response.status), response.status >= 500 ? 503 : response.status);
    }
    return payload;
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    log('warn', 'remote_request_unavailable', { resolver: resolverId, error: error?.code ?? error?.name ?? 'network' });
    throw new BridgeError('ROUTE_UNAVAILABLE', 'Нет связи с сервером.');
  }
};

const localGatewayCall = async (pathname, options = {}) => {
  try {
    const response = await fetch(`${GATEWAY_URL}${pathname}`, { signal: AbortSignal.timeout(5_000), ...options });
    const payload = await parseRemoteBody(response);
    return { response, payload };
  } catch {
    throw new BridgeError('LOCAL_GATEWAY_UNAVAILABLE', 'Локальный печатный шлюз недоступен.');
  }
};

let discoveryCache = { at: 0, printers: [] };
const discoverPrinters = async (force = false) => {
  if (!force && Date.now() - discoveryCache.at < 10_000) return discoveryCache.printers;
  const body = null;
  const { response, payload } = await localGatewayCall('/system-printers', {
    headers: { 'x-mahabbat-signature': signBody({ method: 'GET', path: '/system-printers', body }) },
  });
  if (!response.ok || !Array.isArray(payload.printers)) {
    throw new BridgeError(payload.code ?? 'PRINT_DISCOVERY_UNAVAILABLE', errorCodeMessage(payload.code, response.status), 503);
  }
  discoveryCache = { at: Date.now(), printers: payload.printers };
  return discoveryCache.printers;
};

const gatewayHealth = async () => {
  try {
    const { response, payload } = await localGatewayCall('/health');
    return response.ok && payload.status === 'ok' ? payload : null;
  } catch {
    return null;
  }
};

const remoteHealth = async () => {
  try {
    const payload = await remoteCall(PRINT_RESOLVER_ID, { command: 'health', gatewayId: GATEWAY_ID });
    return payload?.status === 'ok';
  } catch {
    return false;
  }
};

const statusText = (value) => ({
  CONNECTED: 'Подключён',
  UNAVAILABLE: 'Недоступен',
  NOT_FOUND: 'Не найден',
  UNKNOWN: 'Состояние неизвестно',
  READY: 'Готов',
  NOT_CONFIGURED: 'Не выбран',
  RUNNING: 'Работает',
  STOPPED: 'Остановлен',
}[value] ?? 'Состояние неизвестно');

const activeDevice = () => state.devices.find((device) => device.id === state.activeDeviceId) ?? null;
const deviceForRoute = (id) => state.devices.find((device) => device.id === id) ?? null;

const printerState = (device, printers) => {
  if (!device) return { state: 'NOT_CONFIGURED', label: statusText('NOT_CONFIGURED') };
  if (device.connectionType === 'ETHERNET_RAW_TCP') {
    if (device.status === 'REACHABLE') return { state: 'READY', label: statusText('READY') };
    if (device.status === 'UNREACHABLE') return { state: 'UNAVAILABLE', label: statusText('UNAVAILABLE') };
    return { state: 'UNKNOWN', label: statusText('UNKNOWN') };
  }
  const system = printers.find((printer) => printer.systemQueueName === device.systemQueueName);
  if (!system) return { state: 'NOT_FOUND', label: statusText('NOT_FOUND'), queue: device.systemQueueName };
  if (system.isAvailable) return { state: 'READY', label: statusText('READY'), queue: system.systemQueueName };
  if (system.status === 'UNAVAILABLE') return { state: 'UNAVAILABLE', label: statusText('UNAVAILABLE'), queue: system.systemQueueName };
  return { state: 'UNKNOWN', label: statusText('UNKNOWN'), queue: system.systemQueueName };
};

const publicPrinters = (printers) => printers.map((printer) => ({
  id: String(printer.id ?? ''),
  name: String(printer.name ?? printer.systemQueueName ?? 'Принтер'),
  systemQueueName: String(printer.systemQueueName ?? ''),
  status: ['CONNECTED', 'UNAVAILABLE', 'UNKNOWN'].includes(printer.status) ? printer.status : 'UNKNOWN',
  isAvailable: Boolean(printer.isAvailable),
  isDefault: Boolean(printer.isDefault),
  capabilityStatus: String(printer.capabilityStatus ?? 'UNKNOWN'),
  driverName: printer.driverName ? String(printer.driverName) : null,
  portName: printer.portName ? String(printer.portName) : null,
}));

const publicRoutes = () => stations.map((station) => {
  const printerDeviceId = String(state.routes[station.id] ?? station.printerDeviceId ?? '').trim() || null;
  const device = deviceForRoute(printerDeviceId);
  return { id: station.id, label: station.label, isActive: station.isActive, printerDeviceId, printerLabel: device?.label ?? null };
});

const statusSnapshot = async () => {
  const [gateway, serverConnected, printersResult] = await Promise.all([
    gatewayHealth(),
    remoteHealth(),
    discoverPrinters().then((value) => ({ printers: value, error: null })).catch((error) => ({ printers: [], error })),
  ]);
  const printers = printersResult.printers;
  const device = activeDevice();
  const resolvedPrinter = printerState(device, printers);
  return {
    service: 'mahabbat-print-bridge',
    gateway: { state: gateway ? 'RUNNING' : 'STOPPED', label: statusText(gateway ? 'RUNNING' : 'STOPPED') },
    server: { state: serverConnected ? 'CONNECTED' : 'UNAVAILABLE', label: serverConnected ? 'Подключён' : 'Нет связи с сервером' },
    printer: { ...resolvedPrinter, label: resolvedPrinter.label },
    mode: device ? 'Windows Printer' : 'Windows Printer',
    lastJob: state.lastJob,
    printers: publicPrinters(printers),
    devices: state.devices.map(safeDevice),
    routes: publicRoutes(),
    discoveryError: printersResult.error ? 'Список принтеров Windows недоступен.' : null,
  };
};

const requireObject = (value) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError('INVALID_REQUEST', 'Проверьте введённые данные.', 400);
  return value;
};

const boundedText = (value, fallback, max = 128) => {
  const text = typeof value === 'string' ? value.trim() : fallback;
  if (!text || text.length > max || /[\u0000-\u001f\u007f]/.test(text)) throw new BridgeError('INVALID_PAYLOAD', 'Проверьте название и выбранное устройство.', 400);
  return text;
};

const boundedNetworkHost = (value) => {
  if (typeof value !== 'string') throw new BridgeError('INVALID_PAYLOAD', 'Укажите IP-адрес сетевого принтера.', 400);
  const host = value.trim();
  const hostnamePattern = /^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/;
  if (!host || host.length > 253 || /[\u0000-\u001f\u007f\s/\\?#]/.test(host) || (isIP(host) === 0 && !hostnamePattern.test(host))) {
    throw new BridgeError('INVALID_PAYLOAD', 'Укажите корректный IP-адрес или имя сетевого принтера.', 400);
  }
  return host;
};

const boundedPort = (value) => {
  const port = typeof value === 'number' ? value : Number(value);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new BridgeError('INVALID_PAYLOAD', 'Укажите порт сетевого принтера.', 400);
  }
  return port;
};

const configurePrinter = async (input) => {
  const body = requireObject(input);
  const connectionType = body.connectionType === 'ETHERNET_RAW_TCP' ? 'ETHERNET_RAW_TCP' : 'WINDOWS_SPOOLER';
  let queue = '';
  let system = null;
  let host = 'windows-spooler';
  let port = 9100;
  if (connectionType === 'WINDOWS_SPOOLER') {
    queue = boundedText(body.systemQueueName, '', 255);
    const printers = await discoverPrinters(true);
    system = printers.find((printer) => printer.systemQueueName === queue);
    if (!system) throw new BridgeError('PRINTER_NOT_FOUND', 'Windows не видит выбранный принтер.', 409);
  } else {
    host = boundedNetworkHost(body.host);
    port = boundedPort(body.port);
  }
  const requestedId = typeof body.deviceId === 'string' ? body.deviceId.trim() : '';
  const existingById = requestedId ? state.devices.find((device) => device.id === requestedId) : null;
  const existingByQueue = connectionType === 'WINDOWS_SPOOLER'
    ? state.devices.find((device) => device.connectionType === 'WINDOWS_SPOOLER' && device.systemQueueName === queue)
    : state.devices.find((device) => device.connectionType === 'ETHERNET_RAW_TCP' && device.host === host && device.port === port);
  const deviceId = existingById?.id ?? existingByQueue?.id;
  const encodingProfile = ['CP866', 'WINDOWS1251', 'UTF8'].includes(body.encodingProfile) ? body.encodingProfile : 'CP866';
  const paperWidth = body.paperWidth === '58' ? '58' : '80';
  const defaultLabel = connectionType === 'WINDOWS_SPOOLER' ? `Принтер · ${system.name ?? queue}` : `Сетевой принтер · ${host}`;
  const payload = {
    ...(deviceId ? { printerDeviceId: deviceId } : {}),
    label: boundedText(body.label, defaultLabel),
    connectionType,
    host,
    port,
    systemQueueName: connectionType === 'WINDOWS_SPOOLER' ? queue : null,
    isActive: body.isActive !== false,
    isPrecheckPrinter: Boolean(body.isPrecheckPrinter),
    paperWidth,
    encodingProfile,
    escPosCodePage: null,
    cutSupport: body.cutSupport !== false,
  };
  const result = await remoteCall(POS_RESOLVER_ID, { command: 'upsertPrinterDevice', payload, crmWorkspaceAuthenticated: true });
  const savedId = String(result?.printerDeviceId ?? '').trim();
  if (!savedId) throw new BridgeError('CONFLICT', 'Принтер не удалось сохранить на сервере.', 409);
  const nextDevice = safeDevice({ ...payload, id: savedId, status: 'CONFIGURED' });
  state.devices = [...state.devices.filter((device) => device.id !== savedId && device.id !== deviceId), nextDevice];
  state.activeDeviceId = savedId;
  await saveState();
  log('info', 'printer_configured', { queue, device: savedId });
  return { device: nextDevice, warning: system && !system.isAvailable ? 'Windows сейчас сообщает, что устройство недоступно.' : null };
};

const testPrint = async (input) => {
  const body = input && typeof input === 'object' ? input : {};
  const requestedId = typeof body.deviceId === 'string' ? body.deviceId.trim() : state.activeDeviceId;
  const device = state.devices.find((candidate) => candidate.id === requestedId);
  if (!device) throw new BridgeError('PRINTER_DEVICE_NOT_FOUND', 'Сначала сохраните принтер.', 409);
  const result = await remoteCall(POS_RESOLVER_ID, {
    command: 'testPrinterDevice',
    payload: { printerDeviceId: device.id, idempotencyKey: randomUUID() },
    crmWorkspaceAuthenticated: true,
  });
  state.activeDeviceId = device.id;
  state.lastJob = { state: 'QUEUED', label: 'Тестовая печать', at: new Date().toISOString(), deviceLabel: device.label };
  await saveState();
  log('info', 'test_print_enqueued', { device: device.id });
  return { message: 'Тестовая печать отправлена в очередь.', printJobId: result?.printJobId ?? null };
};

const saveRoute = async (input) => {
  const body = requireObject(input);
  const stationId = boundedText(body.stationId, '', 64);
  const station = stations.find((candidate) => candidate.id === stationId);
  if (!station) throw new BridgeError('PRODUCTION_STATION_NOT_FOUND', 'Место печати не найдено.', 404);
  const requestedId = body.printerDeviceId === null || body.printerDeviceId === '' || body.printerDeviceId === undefined
    ? null
    : boundedText(body.printerDeviceId, '', 64);
  if (requestedId && !state.devices.some((device) => device.id === requestedId)) {
    throw new BridgeError('PRINTER_DEVICE_NOT_FOUND', 'Сначала сохраните выбранный принтер.', 409);
  }
  await remoteCall(POS_RESOLVER_ID, {
    command: 'upsertProductionStation',
    payload: {
      productionStationId: station.id,
      label: station.label,
      printerDeviceId: requestedId,
      isActive: station.isActive,
    },
    crmWorkspaceAuthenticated: true,
  });
  state.routes[station.id] = requestedId;
  await saveState();
  log('info', 'route_saved', { station: station.id, device: requestedId ?? 'none' });
  return { routes: publicRoutes() };
};

const HTML = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mahabbat Print Bridge</title>
<style>
:root{color-scheme:dark;font-family:Segoe UI,Arial,sans-serif;background:#151617;color:#f5f0e8}*{box-sizing:border-box}body{margin:0;background:linear-gradient(145deg,#151617 0%,#1b1b1d 65%,#241f18 100%);min-height:100vh;overflow-x:hidden}main{width:min(1080px,100%);margin:0 auto;padding:28px 20px 48px}header{display:flex;justify-content:space-between;gap:20px;align-items:flex-start;flex-wrap:wrap;margin-bottom:22px}h1{margin:0;font-size:30px;letter-spacing:-.02em}h2{font-size:20px;margin:0 0 7px}p{color:#b8b0a4;line-height:1.5;margin:6px 0}.lead{max-width:700px}.grid{display:grid;gap:14px}.status-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin-top:18px}.status{background:#211f1d;border:1px solid #3a3631;border-radius:12px;padding:13px 15px;min-width:0}.status small{display:block;color:#9b9286;font-size:12px;margin-bottom:5px}.status strong{font-size:16px}.ok{color:#9bd6b3}.warn{color:#e8c27b}.bad{color:#f0a5a5}.card{background:rgba(22,22,23,.9);border:1px solid #3a3837;border-radius:13px;padding:18px;margin-top:14px;box-shadow:0 12px 30px #00000018}.steps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin:18px 0}.step{display:flex;gap:10px;align-items:flex-start;padding:13px;border-radius:11px;background:#25221e;border:1px solid #49402f}.number{display:grid;place-items:center;flex:0 0 26px;width:26px;height:26px;border-radius:50%;background:#d4aa61;color:#1d1b19;font-weight:800}.step b{display:block;margin:2px 0 3px}.muted{color:#a9a196;font-size:13px}.toolbar{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap}.list{display:grid;gap:9px;margin-top:14px}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:14px;align-items:center;padding:14px;border-radius:10px;background:#1d1d1f;border:1px solid #302f30;min-width:0}.row-title{font-weight:700;overflow-wrap:anywhere}.pill{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:4px 9px;font-size:12px;margin-top:7px;background:#30302f;color:#d6cec2}.pill.ok{background:#183b2c}.pill.warn{background:#49391f}.pill.bad{background:#47262a}.actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}button{border:0;border-radius:8px;padding:10px 14px;font:inherit;font-weight:650;cursor:pointer;color:#fff;background:#b9823d}button:hover{filter:brightness(1.1)}button.secondary{background:#333238;border:1px solid #53505a}button.danger{background:#633039}button:disabled{cursor:not-allowed;opacity:.45}.form-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:14px}label{display:grid;gap:6px;color:#e9e0d5;font-size:13px;min-width:0}input,select{width:100%;min-width:0;border:1px solid #5a5653;border-radius:7px;background:#f7f3ed;color:#1d1c1b;padding:9px 10px;font:inherit}input[type=checkbox]{width:auto;accent-color:#c7904e}label.check{display:flex;align-items:center;gap:8px;margin-top:12px}.form-actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:15px}.message-host{position:sticky;top:10px;z-index:20}.notice{padding:11px 13px;border-radius:9px;background:#193a2e;color:#a7d8bb;margin:14px 0;box-shadow:0 8px 22px #0008}.error{padding:11px 13px;border-radius:9px;background:#48272b;color:#f0b0b0;margin:14px 0;box-shadow:0 8px 22px #0008}.row.selected{border-color:#b9823d;box-shadow:0 0 0 1px #b9823d55}.card.focused{border-color:#b9823d;box-shadow:0 0 0 1px #b9823d55,0 12px 30px #00000018}.busy-indicator{display:inline-flex;align-items:center;gap:8px;color:#e8c27b;font-size:13px}.busy-indicator::before{content:'';width:12px;height:12px;border:2px solid #6a5b45;border-top-color:#e8c27b;border-radius:50%;animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}button.is-busy{pointer-events:none;opacity:.75}.route{display:grid;grid-template-columns:minmax(150px,.7fr) minmax(0,1fr) auto;gap:10px;align-items:center;padding:10px 0;border-bottom:1px solid #343236}.route:last-child{border-bottom:0}.small{font-size:12px;color:#a9a196}.technical{margin-top:9px;color:#9e958b;font-size:12px}.advanced{margin-top:14px;border:1px dashed #514b43;border-radius:10px;padding:12px 14px}.advanced summary{cursor:pointer;color:#e5d7c3;font-weight:650}.empty{padding:16px;border:1px dashed #5d574f;border-radius:10px;color:#aaa298;margin-top:13px}.footer-note{font-size:13px;color:#b3a99b;margin-top:17px}.footer-note b{color:#e4c68e}@media(max-width:720px){main{padding:20px 12px 36px}h1{font-size:26px}.status-grid,.steps{grid-template-columns:1fr}.row{grid-template-columns:1fr}.form-grid{grid-template-columns:1fr}.route{grid-template-columns:1fr;gap:7px}.route button{justify-self:start}.actions{justify-content:flex-start}}
</style></head>
<body><main>
<header><div class="lead"><div class="small">Временное подключение к Mahabbat</div><h1>Печать</h1><p>Выберите принтер, сохраните его и отправьте тестовую печать. Ключи подключения и технические настройки остаются внутри программы.</p></div><div class="actions"><button id="refresh" class="secondary">Обновить список</button><button id="close" class="danger">Закрыть</button></div></header>
<div id="message" class="message-host"></div>
<section class="status-grid"><div class="status"><small>Сервер Mahabbat</small><strong id="server-status">Проверяем…</strong></div><div class="status"><small>Принтер</small><strong id="printer-status">Проверяем…</strong></div><div class="status"><small>Последнее задание</small><strong id="job-status">—</strong></div></section>
<section class="steps"><div class="step"><span class="number">1</span><div><b>Выберите устройство</b><span class="muted">Оно должно быть установлено в Windows.</span></div></div><div class="step"><span class="number">2</span><div><b>Сохраните принтер</b><span class="muted">Название увидят сотрудники.</span></div></div><div class="step"><span class="number">3</span><div><b>Проверьте печать</b><span class="muted">Задание уйдёт обычным путём Mahabbat.</span></div></div></section>
<section class="card"><div class="toolbar"><div><h2>Устройства Windows</h2><p class="muted">Здесь показаны принтеры, которые сейчас видит этот компьютер.</p></div><span id="discovery-time" class="small"></span></div><div id="printers" class="list"></div></section>
<section class="advanced"><details><summary>Сетевой принтер — если Windows его не показывает</summary><p class="muted">Обычное подключение выполняется через список Windows выше. Этот запасной вариант нужен только для принтера, подключённого напрямую к сети ресторана. IP-адрес и порт возьмите из настроек самого принтера или у ответственного за сеть.</p><div class="form-grid"><label>Название в Mahabbat<input id="ethernet-label" placeholder="Например, Принтер кухни"></label><label>IP-адрес или имя<input id="ethernet-host" placeholder="Например, 192.168.1.50" inputmode="decimal" autocomplete="off"></label><label>Порт принтера<input id="ethernet-port" type="number" min="1" max="65535" placeholder="Укажите порт"></label></div><div class="form-actions"><button id="save-ethernet" class="secondary">Сохранить сетевой принтер</button><span class="small">Порт не подставляется автоматически.</span></div></details></section>
<section class="card" id="printer-config"><h2>Настройка выбранного принтера</h2><p class="muted">Для обычного подключения не нужно вводить IP-адрес, порт или драйвер.</p><div class="form-grid"><label>Название в Mahabbat<input id="label" placeholder="Например, Принтер кухни"></label><label>Устройство Windows<select id="queue"><option value="">Сначала выберите устройство</option></select></label><label>Профиль печати<select id="encoding"><option value="CP866">ESC/POS · CP866</option><option value="WINDOWS1251">ESC/POS · Windows-1251</option><option value="UTF8">ESC/POS · UTF-8</option></select></label><label>Ширина бумаги<select id="paper"><option value="80">80 мм</option><option value="58">58 мм</option></select></label></div><label class="check"><input id="precheck" type="checkbox"> Использовать также для пречеков</label><div class="form-actions"><button id="save">Сохранить принтер</button><button id="test" class="secondary" disabled>Тестовая печать</button><span id="selected-note" class="small"></span><span id="action-status" class="busy-indicator" hidden></span></div></section>
<section class="card"><h2>Места печати</h2><p class="muted">Один сохранённый принтер можно назначить нескольким местам: кухня, бар, мангал или пречек.</p><div id="routes"></div><div id="routes-empty" class="empty" hidden>Места печати пока не переданы этому временному подключению. Их можно назначить в Mahabbat → Печать после входа администратора.</div></section>
<p class="footer-note"><b>Важно:</b> «Отправлено» означает, что задание прошло до настроенного шлюза. Бумагу, размер 80 мм и автоотрезку нужно подтвердить на реальном принтере отдельно.</p>
</main><script>
const state={data:null,deviceId:'',connectionType:'',selectedQueue:'',busy:0};
const $=(id)=>document.getElementById(id);
const esc=(value)=>String(value??'').replace(/[&<>"']/g,(c)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const statusLabel=(value)=>({CONNECTED:'Подключён',UNAVAILABLE:'Недоступен',UNKNOWN:'Состояние неизвестно',READY:'Готов',NOT_FOUND:'Не найден',NOT_CONFIGURED:'Не выбран',STOPPED:'Остановлен'}[value]||'Состояние неизвестно');
const tone=(value)=>value==='CONNECTED'||value==='READY'?'ok':value==='UNAVAILABLE'||value==='NOT_FOUND'?'bad':'warn';
function showMessage(text,kind='notice'){ $('message').innerHTML=text?'<div class="'+kind+'">'+esc(text)+'</div>':''; }
function setActionStatus(text=''){const el=$('action-status');if(!el)return;el.hidden=!text;el.textContent=text;}
async function withBusy(button,busyText,work){const original=button?.textContent||'';state.busy++;if(button){button.disabled=true;button.classList.add('is-busy');button.textContent=busyText;}setActionStatus(busyText);try{return await work();}finally{state.busy=Math.max(0,state.busy-1);if(button){button.disabled=false;button.classList.remove('is-busy');button.textContent=original;}setActionStatus('');}}
async function call(path,options={}){const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),20000);try{const r=await fetch(path,{...options,signal:controller.signal,headers:{'content-type':'application/json',...(options.headers||{})}});const p=await r.json().catch(()=>({}));if(!r.ok)throw new Error(p.message||'Не удалось выполнить действие.');return p;}catch(e){if(e?.name==='AbortError')throw new Error('Операция заняла слишком много времени. Проверьте связь и попробуйте ещё раз.');throw e;}finally{clearTimeout(timeout);}}
function selectPrinter(queue,deviceId='',label=''){ const data=state.data; state.connectionType='WINDOWS_SPOOLER'; state.selectedQueue=queue||''; state.deviceId=deviceId||data?.devices?.find((d)=>d.systemQueueName===queue)?.id||''; $('queue').value=state.selectedQueue; $('label').value=label||data?.devices?.find((d)=>d.id===state.deviceId)?.label||''; const device=data?.devices?.find((d)=>d.id===state.deviceId); if(device){$('encoding').value=device.encodingProfile||'CP866';$('paper').value=device.paperWidth||'80';$('precheck').checked=!!device.isPrecheckPrinter;} $('test').disabled=!state.deviceId; $('selected-note').textContent=state.deviceId?'Принтер уже сохранён — можно изменить настройки':'Новый принтер — нажмите «Сохранить принтер»'; renderPrinters(); const card=$('printer-config');card?.classList.add('focused');setTimeout(()=>card?.classList.remove('focused'),1800);showMessage('Выбран «'+(label||queue)+'». Проверьте настройки ниже и нажмите «Сохранить принтер».');card?.scrollIntoView({behavior:'smooth',block:'center'}); }
function selectEthernet(device){ state.connectionType='ETHERNET_RAW_TCP'; state.deviceId=device.id||''; $('ethernet-label').value=device.label||''; $('ethernet-host').value=device.host||''; $('ethernet-port').value=device.port||''; $('encoding').value=device.encodingProfile||'CP866'; $('paper').value=device.paperWidth||'80'; $('precheck').checked=!!device.isPrecheckPrinter; document.querySelector('.advanced details').open=true; document.querySelector('.advanced').scrollIntoView({behavior:'smooth',block:'start'}); }
function renderPrinters(){ const data=state.data; const list=data?.printers||[]; const ethernet=(data?.devices||[]).filter((d)=>d.connectionType==='ETHERNET_RAW_TCP'); $('queue').innerHTML='<option value="">Сначала выберите устройство</option>'+list.map((p)=>'<option value="'+esc(p.systemQueueName)+'">'+esc(p.name)+'</option>').join(''); if(state.selectedQueue&&list.some((p)=>p.systemQueueName===state.selectedQueue)){$('queue').value=state.selectedQueue;}else if(state.selectedQueue){state.selectedQueue='';$('queue').value='';showMessage('Ранее выбранный принтер больше не найден в Windows. Выберите устройство снова.','error');} const configured=new Map((data?.devices||[]).filter((d)=>d.connectionType!=='ETHERNET_RAW_TCP').map((d)=>[d.systemQueueName,d])); const windowsHtml=list.map((p)=>{const d=configured.get(p.systemQueueName); const st=p.status||'UNKNOWN'; return '<div class="row '+(p.systemQueueName===state.selectedQueue?'selected':'')+'"><div><div class="row-title">'+esc(p.name)+(p.isDefault?' <span class="small">· по умолчанию</span>':'')+'</div><span class="pill '+tone(st)+'">● '+esc(statusLabel(st))+'</span><span class="small"> · совместимость не проверена</span>'+(d?'<div class="technical">Сохранён как «'+esc(d.label)+'»</div>':'')+'<details class="technical"><summary>Подробнее</summary><div>Системное имя: '+esc(p.systemQueueName)+' · Драйвер: '+esc(p.driverName||'не указан')+' · Порт: '+esc(p.portName||'не указан')+'</div></details></div><div class="actions"><button data-select="'+esc(p.systemQueueName)+'" class="'+(d?'secondary':'')+'">'+(p.systemQueueName===state.selectedQueue?'Выбрано':(d?'Изменить':'Выбрать и настроить'))+'</button>'+(d?'<button data-test="'+esc(d.id)+'" class="secondary" '+(!p.isAvailable?'disabled':'')+'>Тестовая печать</button>':'')+'</div></div>';}).join(''); const ethernetHtml=ethernet.map((d)=>'<div class="row"><div><div class="row-title">'+esc(d.label||'Сетевой принтер')+'</div><span class="pill warn">● Состояние неизвестно</span><span class="small"> · сетевое подключение</span><div class="technical">Сохранённое сетевое устройство</div><details class="technical"><summary>Подробнее</summary><div>Адрес: '+esc(d.host||'не указан')+' · Порт: '+esc(d.port||'не указан')+'</div></details></div><div class="actions"><button data-ethernet-edit="'+esc(d.id)+'" class="secondary">Изменить</button><button data-test="'+esc(d.id)+'" class="secondary">Тестовая печать</button></div></div>').join(''); $('printers').innerHTML=(windowsHtml+ethernetHtml)||'<div class="empty">Windows пока не сообщила об установленных принтерах. Установите принтер в Windows и нажмите «Обновить список».</div>';$('printers').querySelectorAll('[data-select]').forEach((b)=>b.onclick=()=>{const p=list.find((x)=>x.systemQueueName===b.dataset.select);const d=configured.get(b.dataset.select);selectPrinter(b.dataset.select,d?.id||'',d?.label||('Принтер · '+(p?.name||'')));});$('printers').querySelectorAll('[data-ethernet-edit]').forEach((b)=>b.onclick=()=>{const d=ethernet.find((x)=>x.id===b.dataset.ethernetEdit);if(d)selectEthernet(d);});$('printers').querySelectorAll('[data-test]').forEach((b)=>b.onclick=()=>runTest(b.dataset.test,b)); }
function renderRoutes(){ const rows=state.data?.routes||[]; $('routes-empty').hidden=rows.length>0; $('routes').innerHTML=rows.map((r)=>'<div class="route"><div><b>'+esc(r.label)+'</b><div class="small">'+(r.printerLabel?'Принтер выбран: '+esc(r.printerLabel):'Маршрут ещё не настроен')+'</div></div><select data-route="'+esc(r.id)+'"><option value="">Без принтера</option>'+(state.data?.devices||[]).map((d)=>'<option value="'+esc(d.id)+'" '+(d.id===r.printerDeviceId?'selected':'')+'>'+esc(d.label)+'</option>').join('')+'</select><button data-save-route="'+esc(r.id)+'" class="secondary">Сохранить</button></div>').join('');$('routes').querySelectorAll('[data-save-route]').forEach((b)=>b.onclick=async()=>{const select=$('routes').querySelector('[data-route="'+CSS.escape(b.dataset.saveRoute)+'"]');try{await withBusy(b,'Сохраняем…',async()=>{await call('/api/routes/save',{method:'POST',body:JSON.stringify({stationId:b.dataset.saveRoute,printerDeviceId:select.value||null})});showMessage('Место печати сохранено.');await load();});}catch(e){showMessage(e.message,'error');}}); }
function renderStatus(){const d=state.data;if(!d)return;$('server-status').textContent=d.server?.label||'Нет связи с сервером';$('server-status').className=tone(d.server?.state);$('printer-status').textContent=d.printer?.label||'Не выбран';$('printer-status').className=tone(d.printer?.state);$('job-status').textContent=d.lastJob?('Отправлено · '+new Date(d.lastJob.at).toLocaleTimeString('ru-RU')):'—';$('job-status').className=d.lastJob?'ok':'';}
function render(){ const d=state.data;if(!d)return;renderStatus();$('discovery-time').textContent='Список обновляется вручную';renderPrinters();renderRoutes();$('test').disabled=!state.deviceId; }
async function load(background=false){if(background&&state.busy)return;try{state.data=await call('/api/status');if(!state.deviceId)state.deviceId=state.data.devices?.[0]?.id||'';if(!state.selectedQueue&&state.deviceId){const active=state.data.devices?.find((d)=>d.id===state.deviceId);if(active?.connectionType==='WINDOWS_SPOOLER'&&active.systemQueueName)state.selectedQueue=active.systemQueueName;}if(background)renderStatus();else render();}catch(e){if(!background)showMessage(e.message,'error');}}
async function refresh(){try{await withBusy($('refresh'),'Обновляем…',async()=>{state.data=await call('/api/refresh',{method:'POST'});render();showMessage('Список устройств обновлён. Можно выбрать нужный принтер.');});}catch(e){showMessage(e.message,'error');}}
async function save(){try{const queue=$('queue').value;if(!queue){showMessage('Сначала нажмите «Выбрать и настроить» у нужного принтера.','error');return;}await withBusy($('save'),'Сохраняем…',async()=>{const result=await call('/api/configure',{method:'POST',body:JSON.stringify({deviceId:state.deviceId,label:$('label').value,systemQueueName:queue,encodingProfile:$('encoding').value,paperWidth:$('paper').value,isPrecheckPrinter:$('precheck').checked})});state.deviceId=result.device.id;state.selectedQueue=result.device.systemQueueName||queue;showMessage(result.warning||'Готово: принтер сохранён. Теперь нажмите «Тестовая печать».');await load();});}catch(e){showMessage(e.message,'error');}}
async function saveEthernet(){try{const host=$('ethernet-host').value.trim();const port=Number($('ethernet-port').value);if(!host||!Number.isInteger(port)||port<1||port>65535){showMessage('Укажите IP-адрес и порт сетевого принтера.','error');return;}await withBusy($('save-ethernet'),'Сохраняем…',async()=>{const result=await call('/api/configure',{method:'POST',body:JSON.stringify({deviceId:state.connectionType==='ETHERNET_RAW_TCP'?state.deviceId:'',connectionType:'ETHERNET_RAW_TCP',label:$('ethernet-label').value,host,port,encodingProfile:$('encoding').value,paperWidth:$('paper').value,isPrecheckPrinter:$('precheck').checked})});state.connectionType='ETHERNET_RAW_TCP';state.deviceId=result.device.id;showMessage('Готово: сетевой принтер сохранён. Теперь можно выполнить тестовую печать.');await load();});}catch(e){showMessage(e.message,'error');}}
async function runTest(deviceId=state.deviceId,button=$('test')){try{if(!deviceId){showMessage('Сначала сохраните принтер.','error');return;}await withBusy(button,'Отправляем…',async()=>{await call('/api/test-print',{method:'POST',body:JSON.stringify({deviceId})});showMessage('Тестовая печать отправлена. Проверьте, вышла ли бумага на принтере.');await load();});}catch(e){showMessage(e.message,'error');}}
$('refresh').onclick=refresh;$('save').onclick=save;$('save-ethernet').onclick=saveEthernet;$('test').onclick=()=>runTest(state.deviceId,$('test'));$('close').onclick=async()=>{if(confirm('Закрыть Mahabbat Print Bridge?')){await fetch('/api/stop',{method:'POST'});document.body.innerHTML='<main><h1>Программа закрыта</h1><p>Окно можно закрыть.</p></main>';}};$('queue').onchange=()=>{const p=state.data?.printers?.find((x)=>x.systemQueueName===$('queue').value);const d=state.data?.devices?.find((x)=>x.systemQueueName===$('queue').value);selectPrinter($('queue').value,d?.id||'',d?.label||('Принтер · '+(p?.name||'')));};load();setInterval(()=>load(true),5000);
</script></body></html>`;

let gatewayProcess = null;
let stopping = false;

const startGateway = async () => {
  if (!REMOTE_API_URL || !INTERNAL_SECRET) {
    log('error', 'configuration_incomplete', { missing: !REMOTE_API_URL ? 'TWENTY_API_URL' : 'MAHABBAT_INTERNAL_ROUTE_SECRET' });
    return;
  }
  const gatewayPath = path.join(ROOT, 'gateway', 'print-gateway.mjs');
  const env = { ...process.env };
  for (const name of ['TWENTY_API_KEY', 'MAHABBAT_API_KEY', 'TWENTY_APP_ACCESS_TOKEN']) delete env[name];
  Object.assign(env, {
    TWENTY_API_URL: REMOTE_API_URL,
    MAHABBAT_INTERNAL_ROUTE_SECRET: INTERNAL_SECRET,
    PRINT_GATEWAY_MODE: 'REMOTE',
    PRINT_GATEWAY_HOST: GATEWAY_HOST,
    PRINT_GATEWAY_PORT: String(GATEWAY_PORT),
    PRINT_GATEWAY_ID: GATEWAY_ID,
    PRINT_GATEWAY_POLL_MS: configValue('PRINT_GATEWAY_POLL_MS', '1500'),
    PRINT_GATEWAY_CONNECT_TIMEOUT_MS: configValue('PRINT_GATEWAY_CONNECT_TIMEOUT_MS', '5000'),
    PRINT_GATEWAY_AUTO_RETRY_LIMIT: configValue('PRINT_GATEWAY_AUTO_RETRY_LIMIT', '2'),
    CLOUDFLARE_ACCESS_CLIENT_ID: ACCESS_CLIENT_ID,
    CLOUDFLARE_ACCESS_CLIENT_SECRET: ACCESS_CLIENT_SECRET,
  });
  try {
    gatewayProcess = spawn(process.execPath, [gatewayPath], { cwd: ROOT, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    gatewayProcess.stdout.setEncoding('utf8');
    gatewayProcess.stderr.setEncoding('utf8');
    gatewayProcess.stdout.on('data', (chunk) => chunk.split(/\r?\n/).filter(Boolean).forEach((line) => log('info', 'gateway', { line })));
    gatewayProcess.stderr.on('data', (chunk) => chunk.split(/\r?\n/).filter(Boolean).forEach((line) => log('warn', 'gateway', { line })));
    gatewayProcess.once('error', (error) => log('error', 'gateway_process_error', { error: error?.code ?? error?.name ?? 'process' }));
    gatewayProcess.once('exit', (code, signal) => {
      log('info', 'gateway_stopped', { code: code ?? 'none', signal: signal ?? 'none' });
      gatewayProcess = null;
    });
  } catch (error) {
    log('error', 'gateway_start_failed', { error: error?.code ?? error?.name ?? 'process' });
  }
};

const openBrowser = () => {
  if (process.argv.includes('--no-browser') || configValue('MAHABBAT_BRIDGE_NO_BROWSER') === '1') return;
  const url = `http://${UI_HOST}:${UI_PORT}/`;
  try {
    const browser = spawn('rundll32.exe', ['url.dll,FileProtocolHandler', url], { detached: true, stdio: 'ignore', windowsHide: true });
    browser.unref();
  } catch {
    log('warn', 'browser_open_failed');
  }
};

const shutdown = () => {
  if (stopping) return;
  stopping = true;
  log('info', 'bridge_stopping');
  if (gatewayProcess) {
    try { gatewayProcess.kill(); } catch { /* already stopped */ }
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500).unref();
};

const handler = async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? `${UI_HOST}:${UI_PORT}`}`);
  if (req.method === 'GET' && url.pathname === '/') { htmlResponse(res, HTML); return; }
  if (req.method === 'GET' && url.pathname === '/api/health') { jsonResponse(res, 200, { status: 'ok', service: 'mahabbat-print-bridge' }); return; }
  if (req.method === 'GET' && url.pathname === '/api/status') { jsonResponse(res, 200, await statusSnapshot()); return; }
  if (req.method === 'GET' && url.pathname === '/api/printers') { jsonResponse(res, 200, { printers: publicPrinters(await discoverPrinters(true)) }); return; }
  if (req.method === 'POST' && url.pathname === '/api/refresh') { await discoverPrinters(true); jsonResponse(res, 200, await statusSnapshot()); return; }
  if (req.method === 'POST' && url.pathname === '/api/configure') { jsonResponse(res, 200, await configurePrinter(await parseRequestBody(req))); return; }
  if (req.method === 'POST' && url.pathname === '/api/test-print') { jsonResponse(res, 200, await testPrint(await parseRequestBody(req))); return; }
  if (req.method === 'POST' && url.pathname === '/api/routes/save') { jsonResponse(res, 200, await saveRoute(await parseRequestBody(req))); return; }
  if (req.method === 'POST' && url.pathname === '/api/stop') { jsonResponse(res, 200, { status: 'stopping' }); setTimeout(shutdown, 50).unref(); return; }
  jsonResponse(res, 404, { code: 'NOT_FOUND', message: 'Страница не найдена.' });
};

const server = createServer((req, res) => {
  handler(req, res).catch((error) => {
    const bridgeError = error instanceof BridgeError ? error : new BridgeError('BRIDGE_ERROR', 'Не удалось выполнить действие.', 503);
    log('warn', 'request_failed', { method: req.method, path: req.url, code: bridgeError.code, status: bridgeError.status });
    if (!res.headersSent) jsonResponse(res, bridgeError.status, { code: bridgeError.code, message: bridgeError.publicMessage });
  });
});

await startGateway();
await new Promise((resolve) => server.listen(UI_PORT, UI_HOST, resolve));
log('info', 'bridge_started', { uiPort: UI_PORT, gatewayPort: GATEWAY_PORT, gatewayId: GATEWAY_ID });
openBrowser();
process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);
