#!/usr/bin/env node
// Mahabbat tray companion: localhost status, one-click open/backup, daily backup.
// Runs from the installed app dir; talks to docker + scripts, never to the net.
// Usage: node tray.mjs [--root <deploy-root>]
import { spawn, execFile } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? String(args[i + 1] ?? fallback) : fallback;
};
const DEPLOY_ROOT = path.resolve(arg('--root', path.join(ROOT, '..', '..')));

const ps = (script, extra = [], env = {}) =>
  new Promise((resolve) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(DEPLOY_ROOT, 'scripts', script), ...extra], { cwd: DEPLOY_ROOT, env: { ...process.env, ...env } });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve({ code, out }));
    child.on('error', (e) => resolve({ code: 1, out: e.message }));
  });

const state = { crm: 'unknown', pos: 'unknown', print: 'unknown', lastBackup: null };

async function probe(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(4000) });
    return r.ok;
  } catch { return false; }
}

async function refresh() {
  state.crm = (await probe('http://localhost:3000/healthz')) ? 'ok' : 'down';
  state.pos = (await probe('http://localhost:3100/health')) ? 'ok' : 'down';
  state.print = (await probe('http://127.0.0.1:3110/health')) ? 'ok' : 'down';
  return state;
}

async function dailyBackup() {
  // Ночная копия: DPAPI-ключ ночного шифрования через env (Unprotect делает
  // tray-host.ps1, сюда приходит только base64). Ручная — бумажный пароль
  // из диалога трея через MAHABBAT_BACKUP_PASSWORD. Plaintext запрещён.
  const childEnv = { MAHABBAT_BACKUP_NONINTERACTIVE: '1' };
  if (process.env.MAHABBAT_BACKUP_NIGHTLY_B64) childEnv.MAHABBAT_BACKUP_NIGHTLY_B64 = process.env.MAHABBAT_BACKUP_NIGHTLY_B64;
  if (process.env.MAHABBAT_BACKUP_PASSWORD) childEnv.MAHABBAT_BACKUP_PASSWORD = process.env.MAHABBAT_BACKUP_PASSWORD;
  const r = await ps('mahabbat-backup.ps1', ['-NonInteractive'], childEnv);
  if (r.code === 0) state.lastBackup = new Date().toISOString();
  return r;
}

async function updateOp(action, extra = []) {
  const r = await ps('mahabbat-update.ps1', ['-Action', action, ...extra]);
  return r;
}

// Minimal tray via PowerShell NotifyIcon host: this process exposes state
// over stdout JSON for the WinForms host below. Kept dependency-free.
if (process.argv.includes('--json')) {
  console.log(JSON.stringify(await refresh()));
  process.exit(0);
}

if (process.argv.includes('--backup-now')) {
  const r = await dailyBackup();
  console.log(r.code === 0 ? 'BACKUP OK' : 'BACKUP FAILED');
  console.log(r.out.split('\n').slice(-8).join('\n'));
  process.exit(r.code === 0 ? 0 : 1);
}

if (process.argv.includes('--check-update')) {
  const json = process.argv.includes('--json-update');
  const r = await updateOp('check', json ? ['-Json'] : []);
  console.log(r.out.trimEnd() || (r.code === 0 ? 'UPDATE CHECK DONE' : 'UPDATE CHECK FAILED'));
  process.exit(r.code === 0 ? 0 : 1);
}

if (process.argv.includes('--apply-update')) {
  // Только явный ручной запуск: backup-gate внутри скрипта обязателен.
  const r = await updateOp('apply');
  console.log(r.code === 0 ? 'UPDATE OK' : 'UPDATE FAILED');
  console.log(r.out.split('\n').slice(-10).join('\n'));
  process.exit(r.code === 0 ? 0 : 1);
}

if (process.argv.includes('--rotate-key')) {
  const r = await ps('mahabbat-rotate-key.ps1');
  console.log(r.code === 0 ? 'ROTATE OK' : 'ROTATE FAILED');
  console.log(r.out.split('\n').slice(-5).join('\n'));
  process.exit(r.code === 0 ? 0 : 1);
}

console.log('Mahabbat tray companion. Use --json for status, --backup-now for backup.');
console.log('The Windows host (tray-host.ps1) renders the NotifyIcon and calls back here.');
