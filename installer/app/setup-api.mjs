#!/usr/bin/env node
// Mahabbat Setup API: localhost-only companion for the installer wizard.
// Serves wizard.html + JSON endpoints that run the existing PowerShell
// deployment scripts step by step. No secrets leave the machine; the API
// binds 127.0.0.1 and the installer opens it in the default browser.
// Usage: node setup-api.mjs [--port 3119] [--root <deploy-root>]
import { spawn, spawnSync } from 'node:child_process';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, unlink, writeFile } from 'node:fs/promises';
import { tmpdir as osTmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parsePlanCounts, parseSeedPreview } from './preview-counts.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? String(args[i + 1] ?? fallback) : fallback;
};
const PORT = Number(arg('--port', '3119'));
const DEPLOY_ROOT = path.resolve(arg('--root', path.join(ROOT, '..', '..')));
// Reopening the installed shortcut must reuse the live API and its token.
try {
  const existing = await fetch(`http://127.0.0.1:${PORT}/health`, { signal: AbortSignal.timeout(1000) });
  if (existing.ok && (await existing.json()).service === 'mahabbat-setup') {
    console.log(`Mahabbat setup API already running on http://127.0.0.1:${PORT}/`);
    process.exit(0);
  }
} catch {}
const PS = 'powershell.exe';
const PS_ARGS = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'];
// Одноразовый setup-токен: setup-api пишет его в .private/setup-token
// (user-only ACL через icacls), визард читает локально и отдаёт в заголовке.
// POST без токена → 401. Токен из argv/env — только из файла (ps не видно).
const PRIVATE_DIR = path.join(DEPLOY_ROOT, '.private');
const UPDATE_TARGET_FILE = path.join(PRIVATE_DIR, 'update-target.json');
const SETUP_TOKEN_PATH = path.join(PRIVATE_DIR, 'setup-token');
const SETUP_TOKEN = randomBytes(32).toString('hex');
try {
  await mkdir(PRIVATE_DIR, { recursive: true });
  await writeFile(SETUP_TOKEN_PATH, SETUP_TOKEN + '\n', { mode: 0o600 });
  if (process.platform === 'win32') {
    spawnSync('icacls.exe', [SETUP_TOKEN_PATH, '/inheritance:r', '/grant:r', `${process.env.USERNAME}:F`, '*S-1-5-18:F', '*S-1-5-32-544:F'], { stdio: 'ignore' });
  }
} catch { /* best-effort: файл создан, ACL проверит doctor */ }
const RATE = new Map(); // ip -> { count, reset }
const checkRate = (req) => {
  const now = Date.now();
  const ip = req.socket?.remoteAddress || 'local';
  const slot = RATE.get(ip) || { count: 0, reset: now + 60000 };
  if (now > slot.reset) { slot.count = 0; slot.reset = now + 60000; }
  slot.count += 1;
  RATE.set(ip, slot);
  return slot.count <= 60; // 60 POST/мин с localhost достаточно мастеру
};
const BODY_CAP = 32 * 1024;
const SETUP_ORIGIN = `http://127.0.0.1:${PORT}`;
const checkSetupAuth = (req) =>
  req.headers['x-setup-token'] === SETUP_TOKEN;
const NOISE = /^(Pulling|Copying|Digest:|Status:|Creating|Created|Container|Waiting|Healthy|Starting|Started|Finished|DONE|#\d|exporting|naming|unpacking|Pull complete|Download complete|Load complete)/i;
const cleanLines = (lines) =>
  (lines || [])
    .map((l) => String(l).trim())
    .filter((l) => l && !NOISE.test(l) && l.length <= 160)
    .slice(-25);

const runPs = (script, extra = [], env = {}) =>
  new Promise((resolve) => {
    const childEnv = { ...process.env, ...env };
    // PowerShell 7 module paths cannot be reused by Windows PowerShell 5.1.
    // Let powershell.exe construct its own default paths, including Security.
    for (const key of Object.keys(childEnv)) {
      if (key.toLowerCase() === 'psmodulepath') delete childEnv[key];
    }
    const child = spawn(PS, [...PS_ARGS, path.join(DEPLOY_ROOT, 'scripts', script), ...extra], { cwd: DEPLOY_ROOT, env: childEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let settled = false;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      child.stdout.destroy();
      child.stderr.destroy();
      resolve({ code, lines: out.split(/\r?\n/).filter(Boolean).slice(-40) });
    };
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', finish);
    // A detached Windows child can retain inherited pipe handles after the
    // deployment script exits. Drain pending output, then finish on exit so
    // starting the persistent print gateway cannot hang the installer.
    child.on('exit', (code) => setTimeout(() => finish(code), 100));
    child.on('error', (e) => resolve({ code: 1, lines: [`spawn failed: ${e.message}`] }));
  });
// Секреты визарда — никогда в argv: scoped env-file в системном tmp
// (mode 600), скрипт читает, стирает env и shred-ит файл после чтения.
const writeScopedEnv = async (values) => {
  const lines = Object.entries(values).map(([k, v]) => `${k}=${String(v ?? '').replace(/[\r\n]/g, '')}`);
  const p = path.join(osTmpdir(), `mahabbat-setup-${randomBytes(8).toString('hex')}.env`);
  await writeFile(p, lines.join('\n') + '\n', { mode: 0o600 });
  return p;
};

const runNode = (scriptArgs, env, cwd) =>
  new Promise((resolve) => {
    const child = spawn(process.execPath, scriptArgs, { cwd, env: { ...process.env, ...env } });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve({ code, lines: out.split(/\r?\n/).filter(Boolean).slice(-40) }));
    child.on('error', (e) => resolve({ code: 1, lines: [`spawn failed: ${e.message}`] }));
  });

const readEnv = async () => {
  try {
    const text = await readFile(path.join(DEPLOY_ROOT, '.env'), 'utf8');
    const map = {};
    for (const line of text.split(/\r?\n/)) {
      const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
      if (m) map[m[1]] = m[2];
    }
    return map;
  } catch { return {}; }
};

const bodyOf = async (req) => {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > BODY_CAP) throw Object.assign(new Error('Тело запроса слишком большое.'), { code: 413 });
    chunks.push(c);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { return {}; }
};
const json = (res, code, obj) => {
  const text = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
  res.end(text);
};
// Установка печати: команды POS (upsertPrinterDevice / upsertProductionStation /
// testPrinterDevice) уходят напрямую в app-only резолвер через существующий
// webhook-интерфейс с подписью внутренним секретом — тем же путём, что
// временный печатный мост. CRM-флаг crmWorkspaceAuthenticated выводит strictly
// печатную тройку из-под POS-сессии; секрет берётся только из локального .env
// и никогда не покидает эту машину (запросы идут на localhost).
const POS_RESOLVER_ID = '54be0dfa-2fd6-45bc-be93-6ba4c64a21d9';
const printerSecrets = async () => {
  const env = await readEnv();
  const secret = String(env.MAHABBAT_INTERNAL_ROUTE_SECRET || '').trim();
  const base = String(env.SERVER_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
  return { secret, base };
};
const stableStringify = (value) => {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  if (typeof value === 'object') {
    const record = value;
    const keys = Object.keys(record).filter((key) => {
      const entry = record[key];
      return entry !== undefined && typeof entry !== 'function' && typeof entry !== 'symbol';
    }).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`).join(',')}}`;
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number') return Number.isFinite(value) ? JSON.stringify(value) : 'null';
  return JSON.stringify(value) ?? 'null';
};
const signEnvelope = (envelope, secret) =>
  `v1=${createHmac('sha256', secret).update(stableStringify(envelope), 'utf8').digest('hex')}`;
// Человекочитаемые тексты без кодов — сырые коды/статусы наружу не отдаём.
const printerProblem = (data, fallback) => {
  const code = String(data?.code || '');
  const human = {
    PRINTER_DEVICE_NOT_FOUND: 'Принтер не найден. Обновите список и попробуйте снова.',
    PRINTER_NOT_FOUND: 'Принтер не найден. Обновите список и попробуйте снова.',
    WINDOWS_PRINTER_NOT_FOUND: 'Windows не видит выбранный принтер. Проверьте подключение и обновите список.',
    PRINTER_INACTIVE: 'Принтер отключён. Включите его и попробуйте снова.',
    SYSTEM_PRINTER_NOT_BOUND: 'Принтер не привязан к очереди Windows.',
    PRINT_CONFIG_INVALID: 'Проверьте название принтера.',
    INVALID_PAYLOAD: 'Проверьте название принтера.',
    PRINT_DISCOVERY_UNAVAILABLE: 'Не вижу принтеры Windows. Проверьте, что принтер включён и установлен, затем обновите список.',
    WINDOWS_SPOOLER_UNAVAILABLE: 'Не вижу принтеры Windows. Проверьте, что принтер включён и установлен, затем обновите список.',
    PRINT_GATEWAY_NOT_CONFIGURED: 'Печать ещё не готова: сервер запускается. Подождите минуту и обновите список.',
    PRINT_ADMIN_NOT_CONFIGURED: 'Печать ещё не готова: сервер запускается. Подождите минуту и попробуйте снова.',
    COMMAND_FORBIDDEN: 'Эта операция недоступна из мастера установки.',
    INVALID_SIGNATURE: 'Сервер отклонил подключение. Перезапустите установку.',
    ROUTE_UNAVAILABLE: 'Нет связи с сервером. Проверьте, что система запущена, и попробуйте ещё раз.',
  }[code];
  return human || String(data?.message || fallback || 'Что-то пошло не так. Попробуйте ещё раз.');
};
const printerWebhook = async (envelope) => {
  const { secret, base } = await printerSecrets();
  if (!secret) return { ok: false, error: 'Печать ещё не готова: сервер запускается. Подождите минуту и попробуйте снова.' };
  let r;
  try {
    r = await fetch(`${base}/webhooks/server/${POS_RESOLVER_ID}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mahabbat-signature': signEnvelope(envelope, secret) },
      body: JSON.stringify(envelope),
    });
  } catch {
    return { ok: false, error: 'Нет связи с сервером. Проверьте, что система запущена, и попробуйте ещё раз.' };
  }
  let data = {};
  try { data = await r.json(); } catch { data = {}; }
  if (!r.ok) return { ok: false, error: printerProblem(data, 'Сервер отклонил запрос. Попробуйте ещё раз.') };
  return { ok: true, data };
};
// Печатная тройка идёт с CRM-флагом (как мост и страница «Печать» через
// шлюз): резолвер выводит её из-под POS-сессии и назначает ADMIN-актора.
const printerPosCommand = (command, payload) =>
  printerWebhook({ command, payload, crmWorkspaceAuthenticated: true });
const printerRestList = async (plural) => {
  const { secret, base } = await printerSecrets();
  if (!secret) return { ok: false, error: 'Печать ещё не готова: сервер запускается. Подождите минуту и попробуйте снова.' };
  const env = await readEnv();
  const key = String(env.TWENTY_API_KEY || '').trim();
  if (key.length <= 20) return { ok: false, error: 'Система ещё не готова. Сначала завершите установку.' };
  let r;
  try {
    r = await fetch(`${base}/rest/${plural}?limit=200`, { headers: { Authorization: `Bearer ${key}` } });
  } catch {
    return { ok: false, error: 'Нет связи с сервером. Проверьте, что система запущена, и попробуйте ещё раз.' };
  }
  let data = {};
  try { data = await r.json(); } catch { data = {}; }
  if (!r.ok) return { ok: false, error: printerProblem(data, 'Сервер отклонил запрос. Попробуйте ещё раз.') };
  const rows = data?.data?.[plural];
  return { ok: true, data: Array.isArray(rows) ? rows : [] };
};
const printerJobStatus = async (jobId) => {
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const r = await printerJobById(jobId);
    if (!r.ok) return r;
    const status = String(r.data?.status || 'UNKNOWN');
    if (status === 'SENT' || status === 'CONFIRMED') return { ok: true, status, done: true };
    if (status === 'FAILED') {
      const why = String(r.data?.lastErrorMessage || '').trim();
      return { ok: false, error: why || 'Принтер не смог напечатать тест. Проверьте бумагу и подключение.' };
    }
    // QUEUED/DISPATCHING/OUTCOME_UNKNOWN are all "not on paper yet": never
    // report them as success. OUTCOME_UNKNOWN additionally means the bytes
    // may already have printed — a blind retry would double-print.
    if (status === 'OUTCOME_UNKNOWN') {
      return { ok: true, status, done: false, unknown: true };
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  return { ok: true, status: 'QUEUED', done: false };
};
const printerJobById = async (jobId) => {
  const env = await readEnv();
  const key = String(env.TWENTY_API_KEY || '').trim();
  const { base } = await printerSecrets();
  if (key.length <= 20) return { ok: false, error: 'Система ещё не готова. Сначала завершите установку.' };
  let r;
  try {
    r = await fetch(`${base}/rest/posPrintJobs/${encodeURIComponent(jobId)}`, { headers: { Authorization: `Bearer ${key}` } });
  } catch {
    return { ok: false, error: 'Нет связи с сервером. Проверьте, что система запущена, и попробуйте ещё раз.' };
  }
  let data = {};
  try { data = await r.json(); } catch { data = {}; }
  if (!r.ok) return { ok: false, error: printerProblem(data, 'Сервер отклонил запрос. Попробуйте ещё раз.') };
  return { ok: true, data: data?.data?.posPrintJob ?? data?.data ?? {} };
};
const routes = {
  // Состояние установки: настроено ли уже (ключ + владелец в .env).
  // Визард при загрузке спрашивает это первым делом.
  '/api/status': async () => {
    const env = await readEnv();
    const key = String(env.TWENTY_API_KEY || '').trim();
    const email = String(env.MAHABBAT_VENUE_EMAIL || '').trim();
    const venue = String(env.MAHABBAT_VENUE_NAME || '').trim();
    const ownerCreated = key.length > 20 && email.includes('@');
    let completed = false;
    try { completed = !!JSON.parse(await readFile(path.join(PRIVATE_DIR, 'setup-complete.json'), 'utf8')).completedAt; } catch {}
    return { ok: true, configured: ownerCreated && completed, ownerCreated, venue: venue || 'Махаббат', email };
  },
  '/api/check': async (b) => {
    if (b?.runtime !== true) {
      const r = await runPs('mahabbat-prerequisites.ps1');
      return { ok: r.code === 0, lines: cleanLines(r.lines) };
    }
    // Самолечение: если контейнеров нет, но .env и образы на месте —
    // молча поднимаем стек перед проверкой. Пользователь не должен
    // знать про контейнеры вообще.
    const probe = await runPs('mahabbat-status.ps1');
    const missing = probe.lines.some((l) => /missing\/missing|is missing|not running|PRINT GATEWAY\s+STOPPED/i.test(l));
    if (missing) {
      await runPs('mahabbat-start.ps1');
    }
    const r = await runPs('mahabbat-doctor.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Проверка нашла проблемы. Откройте технические подробности.', lines: cleanLines(r.lines) };
  },
  '/api/bootstrap': async () => {
    const r = await runPs('mahabbat-bootstrap.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Файлы системы не подготовились. Проверьте интернет и попробуйте снова.', lines: cleanLines(r.lines) };
  },
  '/api/start': async () => {
    const r = await runPs('mahabbat-start.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Запуск занял слишком много времени. Перезагрузите компьютер и нажмите «Попробовать снова».', lines: cleanLines(r.lines) };
  },
  // Plan-превью: read-only `plan` без apply. Визард показывает «N создать, M изменить,
  // 0 удалить» + collapsed детали и только потом разрешает «Применить».
  '/api/plan': async () => {
    const r = await runPs('mahabbat-metadata.ps1', ['-Action', 'plan']);
    const counts = parsePlanCounts(r.lines);
    const details = cleanLines(r.lines);
    if (r.code !== 0) return { ok: false, status: 500, error: 'Проверка данных не удалась.', lines: details, ...counts };
    return { ok: true, lines: details, ...counts };
  },
  '/api/apply': async () => {
    const r = await runPs('mahabbat-setup-apply.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, error: 'Применение данных не удалось.', lines: cleanLines(r.lines) };
  },
  // Seed dry-run: ничего не пишет, только считает. Визард показывает
  // «N зон, M столов, K блюд, 2 PIN — существующее пропускается».
  '/api/seed-preview': async () => {
    const env = await readEnv();
    const apiKey = String(env.MAHABBAT_API_KEY || env.TWENTY_API_KEY || '').trim();
    if (apiKey.length <= 20) return { ok: false, status: 400, error: 'Сначала завершите шаг владельца.' };
    const inner = path.join(DEPLOY_ROOT, 'mahabbat-app');
    const r = await runNode([path.join(inner, 'scripts', 'seed-venue.mjs'), '--dry-run'], {
      MAHABBAT_API_URL: 'http://localhost:3000',
      MAHABBAT_API_KEY: apiKey,
      MAHABBAT_POS_SEED_WAITER_PIN: '0000',
      MAHABBAT_POS_SEED_ADMIN_PIN: '0001',
    }, inner);
    const preview = parseSeedPreview(r.lines);
    const details = cleanLines(r.lines);
    if (r.code !== 0) return { ok: false, status: 500, error: 'Не удалось посчитать стартовые данные.', lines: details };
    if (!preview.found) return { ok: false, status: 500, error: 'Не удалось прочитать план стартовых данных.', lines: details };
    return { ok: true, lines: details, ...preview };
  },
  '/api/owner': async (b) => {
    const env = await readEnv();
    if (String(env.TWENTY_API_KEY || '').trim().length > 20) {
      if (String(b.email || '').trim().toLowerCase() !== String(env.MAHABBAT_VENUE_EMAIL || '').trim().toLowerCase()) {
        return { ok: false, status: 409, error: 'Владелец уже создан с другой почтой. Укажите почту первоначальной установки.' };
      }
      return { ok: true, lines: ['Владелец уже создан. Продолжаю установку.'] };
    }
    const email = String(b.email || '').trim().toLowerCase();
    const password = String(b.password || '');
    const venue = String(b.venue || '').trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { ok: false, status: 400, error: 'Проверьте почту.' };
    if (password.length < 8 || password.length > 50) return { ok: false, status: 400, error: 'Пароль — 8–50 символов.' };
    if (venue.length > 60) return { ok: false, status: 400, error: 'Название — до 60 символов.' };
    const envFile = await writeScopedEnv({ MAHABBAT_SETUP_EMAIL: email, MAHABBAT_SETUP_PASSWORD: password, MAHABBAT_SETUP_VENUE: venue });
    try {
      const r = await runPs('mahabbat-setup-owner.ps1', ['-EnvFile', envFile]);
      if (r.code !== 0) return { ok: false, status: 500, error: 'Не удалось создать владельца.', lines: cleanLines(r.lines) };
      return { ok: true, lines: cleanLines(r.lines).filter((l) => !l.includes('MAHABBAT_API_KEY=')) };
    } finally {
      await unlink(envFile).catch(() => {});
    }
  },
  // Printer-preview: какие привязки станций изменятся. Confirm — только при переназначении.
  '/api/printer-preview': async (b) => {
    const queue = String(b.queue || '').trim();
    if (!queue) return { ok: false, status: 400, error: 'Выберите принтер из списка.' };
    const devices = await printerRestList('posPrinterDevices');
    if (!devices.ok) return devices;
    const same = devices.data.find((d) => String(d?.systemQueueName || '') === queue);
    const stations = await printerRestList('posProductionStations');
    if (!stations.ok) return stations;
    const want = [
      ...(b.kitchen !== false ? ['Кухня'] : []),
      ...(b.bar !== false ? ['Бар'] : []),
    ];
    const rows = want.map((label) => {
      const row = stations.data.find((s) => String(s?.label || '').trim().toLowerCase() === label.toLowerCase());
      const currentDevice = devices.data.find((d) => String(d?.id || '') === String(row?.printerDeviceId || ''));
      const current = row ? (String(currentDevice?.label || currentDevice?.systemQueueName || 'другой принтер')) : '—';
      const reassign = !!row?.printerDeviceId && String(row.printerDeviceId) !== String(same?.id || '');
      return { station: label, from: current, to: String(b.label || '').trim() || queue, reassign };
    });
    return { ok: true, deviceLabel: same ? String(same.label || same.systemQueueName || queue) : null, rows, needsConfirm: rows.some((r) => r.reassign) };
  },
  '/api/apply': async () => {
    const r = await runPs('mahabbat-setup-apply.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, error: 'Применение данных не удалось.', lines: cleanLines(r.lines) };
  },
  '/api/seed': async (b) => {
    if (!/^\d{4,8}$/.test(String(b.pinW || '')) || !/^\d{4,8}$/.test(String(b.pinA || ''))) {
      return { ok: false, status: 400, error: 'Оба PIN — 4–8 цифр.' };
    }
    if (String(b.pinW) === String(b.pinA)) return { ok: false, status: 400, error: 'PIN-коды должны отличаться.' };
    const envFile = await writeScopedEnv({ MAHABBAT_SETUP_PIN_W: String(b.pinW), MAHABBAT_SETUP_PIN_A: String(b.pinA) });
    try {
      const r = await runPs('mahabbat-setup-seed.ps1', ['-EnvFile', envFile]);
      if (r.code === 0) {
        await writeFile(path.join(PRIVATE_DIR, 'setup-complete.json'), JSON.stringify({ completedAt: new Date().toISOString() }) + '\n');
      }
      return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Заполнение не удалось.', lines: cleanLines(r.lines) };
    } finally {
      await unlink(envFile).catch(() => {});
    }
  },
  '/api/backup': async (b) => {
    // Пароль копии — только через env дочернего powershell.exe (никогда в argv
    // и логах). Пустой пароль = обычная копия для ночной автоматики.
    const body = b || {};
    const encrypted = body.mode === 'encrypted';
    const password = String(body.password || '');
    const childEnv = {};
    if (encrypted) {
      if (password.length < 10 || password.length > 128) return { ok: false, status: 400, error: 'Пароль копии — 10–128 символов.' };
      childEnv.MAHABBAT_BACKUP_PASSWORD = password;
      childEnv.MAHABBAT_BACKUP_NONINTERACTIVE = '1';
    } else {
      childEnv.MAHABBAT_BACKUP_NONINTERACTIVE = '1';
    }
    // Ручная обычная копия — только с явным -AllowPlaintext + честный варнинг.
    const r = await runPs('mahabbat-backup.ps1', encrypted ? ['-NonInteractive'] : ['-NonInteractive', '-AllowPlaintext'], childEnv);
    if (r.code === 0) {
      const backupPath = r.lines.map(String).map((line) => /^Backup created(?: \([^)]*\))?:\s*(.+)$/.exec(line)).find(Boolean)?.[1]?.trim() || '';
      if (encrypted) return { ok: true, backupPath, lines: ['Копия базы готова и проверена; архив файлов сервера не зашифрован.'] };
      return { ok: true, backupPath, lines: cleanLines(r.lines) };
    }
    return { ok: false, status: 500, error: 'Копия не удалась.', lines: encrypted ? [] : cleanLines(r.lines) };
  },
  '/api/verify-password': async (b) => {
    // «Проверить пароль»: HMAC-only, без restore и без расшифровки.
    const backupDir = String(b.backupDir || '').replace(/[^A-Za-z0-9 _\-.:\\/]/g, '').slice(0, 200);
    const password = String(b.password || '');
    if (!backupDir) return { ok: false, status: 400, error: 'Укажите папку копии.' };
    if (password.length < 10 || password.length > 128) return { ok: false, status: 400, error: 'Пароль копии — 10–128 символов.' };
    const envFile = await writeScopedEnv({ MAHABBAT_VERIFY_PASSWORD: password, MAHABBAT_VERIFY_DIR: backupDir });
    try {
      const r = await runPs('mahabbat-verify-password.ps1', ['-EnvFile', envFile]);
      return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 422, error: 'Неверный пароль или повреждённый файл.', lines: [] };
    } finally {
      await unlink(envFile).catch(() => {});
    }
  },
  '/api/rotate-key': async () => {
    const r = await runPs('mahabbat-rotate-key.ps1');
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Ключ не перевыпущен.', lines: cleanLines(r.lines) };
  },
  // Обновления: read-only check + явный apply с backup-gate внутри скрипта.
  // Никакого silent-auto: apply только по кнопке из визарда. Check показывает
  // версию и изменения целевого Mahabbat (release manifest), а не старого Twenty.
  // Check записывает закреплённую цель (digest по каждому образу + SHA
  // манифеста/локов) в .private/update-target.json; apply ставит ИМЕННО её.
  '/api/update-check': async () => {
    const r = await runPs('mahabbat-update.ps1', ['-Action', 'check', '-Json', '-TargetFile', UPDATE_TARGET_FILE]);
    if (r.code !== 0) return { ok: false, status: 500, error: 'Не удалось проверить обновления. Проверьте интернет и docker login ghcr.io.', lines: cleanLines(r.lines) };
    try {
      const payloadLine = r.lines.map((l) => String(l).trim()).filter((l) => l.startsWith('{')).slice(-1)[0] || '{}';
      const payload = JSON.parse(payloadLine);
      return {
        ok: true,
        updateAvailable: String(payload.updateAvailable || 'unknown'),
        current: String(payload.current || ''),
        available: String(payload.available || ''),
        mahabbatVersion: String(payload.mahabbatVersion || ''),
        pinnedTargets: Array.isArray(payload.pinnedTargets) ? payload.pinnedTargets : [],
        targetFile: String(payload.targetFile || UPDATE_TARGET_FILE),
        manifestSha256: String(payload.manifestSha256 || ''),
        backupFresh: payload.backupFresh === true,
        backupPath: String(payload.backupPath || ''),
        changelog: Array.isArray(payload.changelog) ? payload.changelog.slice(0, 3).map(String) : [],
        lines: cleanLines(payload.lines || r.lines),
      };
    } catch {
      return { ok: false, status: 500, error: 'Проверка обновлений вернула непонятный ответ.', lines: cleanLines(r.lines) };
    }
  },
  '/api/update-apply': async () => {
    // Fail-closed без записи check: apply без закреплённой цели запрещён,
    // runtime не трогаем (скрипт тоже откажет, но визард не должен дёргать docker зря).
    let pinned = null;
    try {
      const raw = await readFile(UPDATE_TARGET_FILE, 'utf8');
      pinned = JSON.parse(raw);
    } catch {
      pinned = null;
    }
    if (!pinned || pinned.schema !== 1 || !Array.isArray(pinned.targets) || !pinned.targets.length) {
      return { ok: false, status: 409, error: 'Сначала нажмите «Проверить обновления»: закреплённая цель отсутствует. Без неё установка запрещена.', lines: [] };
    }
    const r = await runPs('mahabbat-update.ps1', ['-Action', 'apply', '-TargetFile', UPDATE_TARGET_FILE]);
    return r.code === 0 ? { ok: true, lines: cleanLines(r.lines) } : { ok: false, status: 500, error: 'Обновление не удалось (журнал этапов — .private/update-journal.json; при провале здоровья выполнен откат на previous).', lines: cleanLines(r.lines) };
  },
  '/api/update-verify': async () => {
    const r = await runPs('mahabbat-update.ps1', ['-Action', 'verify', '-Json']);
    if (r.code !== 0) return { ok: false, status: 500, error: 'Проверка после обновления не пройдена.', lines: cleanLines(r.lines) };
    try {
      const payloadLine = r.lines.map((l) => String(l).trim()).filter((l) => l.startsWith('{')).slice(-1)[0] || '{}';
      const payload = JSON.parse(payloadLine);
      return { ok: payload.ok !== false, failures: Array.isArray(payload.failures) ? payload.failures : [], lines: cleanLines(payload.lines || r.lines) };
    } catch {
      return { ok: false, status: 500, error: 'Проверка вернула непонятный ответ.', lines: cleanLines(r.lines) };
    }
  },
  '/api/printers': async () => {
    const env = await readEnv();
    const key = String(env.TWENTY_API_KEY || '').trim();
    const { base, secret } = await printerSecrets();
    const local = String(env.PRINT_GATEWAY_MODE || 'LOCAL').toUpperCase() !== 'REMOTE';
    const port = Number(env.PRINT_GATEWAY_PORT || 3110);
    if (local && (!secret || !Number.isInteger(port) || port < 1 || port > 65535)) {
      return { ok: false, error: 'Печать ещё не готова. Проверьте запуск шлюза печати.' };
    }
    const discoveryUrl = local ? `http://127.0.0.1:${port}/system-printers` : `${base}/s/printing/system-printers`;
    const headers = local
      ? { 'x-mahabbat-signature': signEnvelope({ method: 'GET', path: '/system-printers', body: null }, secret) }
      : { Authorization: `Bearer ${key}` };
    let r;
    try {
      r = await fetch(discoveryUrl, { headers, signal: AbortSignal.timeout(15000) });
    } catch {
      return { ok: false, error: 'Нет связи с сервером. Проверьте, что система запущена, и попробуйте ещё раз.' };
    }
    let data = {};
    try { data = await r.json(); } catch { data = {}; }
    if (!r.ok) return { ok: false, error: printerProblem(data, 'Сервер отклонил запрос. Попробуйте ещё раз.') };
    const raw = data?.printers ?? data?.data?.printers ?? [];
    const printers = (Array.isArray(raw) ? raw : [])
      .map((p) => ({
        queue: String(p?.systemQueueName ?? p?.name ?? '').trim(),
        name: String(p?.name ?? p?.systemQueueName ?? '').trim(),
        driver: String(p?.driverName ?? '').trim() || null,
        available: p?.isAvailable !== false,
      }))
      .filter((p) => p.queue);
    if (!printers.length) {
      return { ok: true, printers: [], hint: 'Принтеры не найдены. Проверьте, что принтер включён и установлен в Windows, затем обновите список.' };
    }
    return { ok: true, printers };
  },
  // Сохранение принтера + привязка станций «Кухня»/«Бар» теми же командами,
  // что использует страница «Печать» в CRM. Повтор безопасен: совпадающие
  // записи обновляются, а не дублируются.
  '/api/printer-save': async (b) => {
    const queue = String(b.queue || '').trim();
    const label = String(b.label || '').trim();
    if (!queue || queue.length > 255) return { ok: false, error: 'Выберите принтер из списка.' };
    if (!label || label.length > 60) return { ok: false, error: 'Придумайте название принтера (до 60 символов).' };
    // Ширина и кодировка приходят из визарда — хардкода 80/CP866 больше нет.
    const paperWidth = String(b.paperWidth || '80');
    if (paperWidth !== '58' && paperWidth !== '80') return { ok: false, error: 'Выберите ширину бумаги 58 или 80 мм.' };
    const encodingProfile = String(b.encodingProfile || 'CP866');
    if (encodingProfile !== 'CP866' && encodingProfile !== 'WINDOWS1251' && encodingProfile !== 'UTF8') return { ok: false, error: 'Выберите кодировку печати.' };
    const existing = await printerRestList('posPrinterDevices');
    if (!existing.ok) return existing;
    const same = existing.data.find((d) => String(d?.systemQueueName || '') === queue);
    const saved = await printerPosCommand('upsertPrinterDevice', {
      ...(same?.id ? { printerDeviceId: same.id } : {}),
      label,
      connectionType: 'WINDOWS_SPOOLER',
      systemQueueName: queue,
      host: 'windows-spooler',
      port: 9100,
      isActive: true,
      isPrecheckPrinter: false,
      paperWidth,
      encodingProfile,
      escPosCodePage: encodingProfile === 'CP866' ? 17 : null,
      cutSupport: true,
    });
    if (!saved.ok) return saved;
    const printerDeviceId = String(saved.data?.printerDeviceId || same?.id || '');
    if (!printerDeviceId) return { ok: false, error: 'Не удалось сохранить принтер. Попробуйте ещё раз.' };
    const want = [
      ...(b.kitchen !== false ? [{ label: 'Кухня' }] : []),
      ...(b.bar !== false ? [{ label: 'Бар' }] : []),
    ];
    const stations = [];
    if (want.length) {
      const current = await printerRestList('posProductionStations');
      if (!current.ok) return current;
      for (const s of want) {
        const sameStation = current.data.find((row) => String(row?.label || '').trim().toLowerCase() === s.label.toLowerCase());
        const done = await printerPosCommand('upsertProductionStation', {
          ...(sameStation?.id ? { productionStationId: sameStation.id } : {}),
          label: s.label,
          printerDeviceId,
          isActive: true,
        });
        if (!done.ok) return done;
        stations.push(s.label);
      }
    }
    return { ok: true, printerDeviceId, stations };
  },
  // Тестовая печать той же командой + ожидание итога задания.
  '/api/printer-test': async (b) => {
    const printerDeviceId = String(b.printerDeviceId || '').trim();
    if (!printerDeviceId) return { ok: false, error: 'Сначала сохраните принтер.' };
    const sent = await printerPosCommand('testPrinterDevice', { printerDeviceId, idempotencyKey: randomUUID() });
    if (!sent.ok) return sent;
    const printJobId = String(sent.data?.printJobId || '');
    if (!printJobId) return { ok: false, error: 'Не удалось отправить тест. Попробуйте ещё раз.' };
    const watched = await printerJobStatus(printJobId);
    if (!watched.ok) return watched;
    if (watched.done) return { ok: true, printJobId, message: 'Тест напечатан. Заберите страницу из принтера.' };
    if (watched.unknown) return { ok: true, printJobId, message: 'Неизвестно, вышла ли страница: проверьте бумагу в принтере перед повтором.' };
    return { ok: true, printJobId, message: 'Задание отправлено и ждёт принтер. Проверьте бумагу и заберите страницу через минуту; не нажимайте повтор вслепую.' };
  },
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (req.method === 'GET' && url.pathname === '/health') {
    json(res, 200, { ok: true, service: 'mahabbat-setup' });
    return;
  }
  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/wizard.html')) {
    try {
      let html = await readFile(path.join(ROOT, 'wizard.html'), 'utf8');
      html = html.replaceAll('__SETUP_TOKEN__', SETUP_TOKEN);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(html);
    } catch { res.writeHead(500); res.end('wizard missing'); }
    return;
  }
  if (req.method === 'POST' && routes[url.pathname]) {
    if (!checkRate(req)) { json(res, 429, { ok: false, error: 'Слишком много запросов. Подождите минуту.' }); return; }
    const origin = String(req.headers.origin || '');
    if (origin && origin !== SETUP_ORIGIN && origin !== 'null') { json(res, 403, { ok: false, error: 'Запрос отклонён.' }); return; }
    if (!checkSetupAuth(req)) { json(res, 401, { ok: false, error: 'Мастер установки не распознан. Перезапустите «Mahabbat — установка».' }); return; }
    try {
      const out = await routes[url.pathname](await bodyOf(req));
      const { status, ...body } = out || {};
      json(res, body.ok === false ? (status || 400) : 200, body);
    } catch (e) {
      if (e && e.code === 413) { json(res, 413, { ok: false, error: 'Тело запроса слишком большое.' }); return; }
      json(res, 500, { ok: false, error: String(e?.message || e) });
    }
    return;
  }
  res.writeHead(404); res.end('not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Mahabbat setup API on http://127.0.0.1:${PORT}/`);
});
