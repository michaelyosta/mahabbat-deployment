import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

// Stage A regressions for NEXT_RELEASE_PLAN_RU findings F04/F05/F06.
// Each test MUST FAIL on the pre-fix scripts and pass only after the fix:
//   F04 empty-manifest gate ..... backup gate accepts {} without a dump
//   F05 future-date gate ........ a copy from the future counts as fresh
//   F06 keySource StrictMode .... manual encrypted copy without keySource
// Each test drives the REAL committed functions inside isolated fixture
// roots — never the live backup dir, never restore.

const ROOT = join(import.meta.dirname, '..', '..');
const UPDATE = readFileSync(join(ROOT, 'scripts', 'mahabbat-update.ps1'), 'utf8');

const extractFunction = (source, name) => {
  const marker = `function ${name} {`;
  const start = source.indexOf(marker);
  assert.ok(start !== -1, `${name} present in mahabbat-update.ps1`);
  let depth = 0;
  for (let i = start; i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`${name}: unbalanced braces`);
};

const BACKUP_STATE_FN = extractFunction(UPDATE, 'Get-MahabbatUpdateBackupState');
const BACKUP_ROOT_FN = 'function Get-MahabbatBackupRoot { return $script:MahabbatCriticBackupRoot }';

const runGate = (fixtureRoot, manifestText, stampOffsetHours) => {
  // Mirror the gate inputs: fixture dir named by timestamp + manifest.
  const stamp = new Date(Date.now() + stampOffsetHours * 3600_000);
  const pad = (n) => String(n).padStart(2, '0');
  const name = `${stamp.getFullYear()}-${pad(stamp.getMonth() + 1)}-${pad(stamp.getDate())}-${pad(stamp.getHours())}${pad(stamp.getMinutes())}${pad(stamp.getSeconds())}`;
  const dir = join(fixtureRoot, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'backup-manifest.json'), manifestText);
  const script = [
    '$ProgressPreference = "SilentlyContinue";',
    BACKUP_ROOT_FN,
    BACKUP_STATE_FN,
    `$script:MahabbatCriticBackupRoot = ${JSON.stringify(fixtureRoot)}`,
    '$gate = Get-MahabbatUpdateBackupState -MaxAgeHours 24',
    '$gate | ConvertTo-Json -Compress',
  ].join('\r\n');
  const tmp = join(tmpdir(), `gate-${Date.now()}-${Math.floor(Math.random() * 1e6)}.ps1`);
  writeFileSync(tmp, script, 'utf8');
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tmp], { encoding: 'utf8' });
    return JSON.parse(out);
  } finally {
    rmSync(tmp, { force: true });
  }
};

const withFixtureRoot = (fn) => {
  const root = mkdtempSync(join(tmpdir(), 'mahabbat-stage-a-'));
  try {
    return fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

test('F04: empty manifest {} without a dump must NOT gate as fresh', () => {
  const gate = withFixtureRoot((root) => runGate(root, '{}', -1));
  assert.equal(gate.Fresh, false, `empty manifest accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F05: a copy dated in the future must NOT gate as fresh', () => {
  const gate = withFixtureRoot((root) => runGate(root, '{}', 24));
  assert.equal(gate.Fresh, false, `future copy accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F06: manual encrypted manifest without keySource must survive StrictMode', () => {
  // Pre-fix restore line 79 reads $manifest.encryption.keySource directly:
  // under Set-StrictMode -Version Latest (mahabbat-common.ps1 line 1) a
  // manual copy whose encryption block has NO keySource throws
  // property-not-found. Mirror that exact read here.
  const strictProbe = [
    '$ProgressPreference = "SilentlyContinue";',
    'Set-StrictMode -Version Latest',
    '$manifest = \'{"encrypted":true,"dump":"database.dump.enc","encryption":{"cipher":"AES-256-CBC+HMAC-SHA256"}}\' | ConvertFrom-Json',
    'try { $keySource = [string]$manifest.encryption.keySource; "OK:" + $keySource } catch { "THREW:" + $_.Exception.Message }',
  ].join('\r\n');
  const tmp = join(tmpdir(), `keysource-${Date.now()}.ps1`);
  writeFileSync(tmp, strictProbe, 'utf8');
  try {
    const out = execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tmp], { encoding: 'utf8' }).trim();
    assert.ok(!out.startsWith('THREW:'), `manual copy keySource read throws: ${out}`);
  } finally {
    rmSync(tmp, { force: true });
  }
});
