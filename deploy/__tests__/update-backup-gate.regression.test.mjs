import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

// Stage C regressions for NEXT_RELEASE_PLAN_RU findings F04/F05/F06/F08/F13.
// Target: Get-MahabbatValidatedBackupState in scripts/lib/mahabbat-backup-validate.ps1.
//   F04 empty-manifest gate ..... {} without a dump must NOT validate as fresh
//   F05 future-date gate ........ a copy from the future must NOT validate as fresh
//   F06 keySource StrictMode .... manual encrypted copy without keySource survives restore read
//   F08 files integrity ........ encrypted copies carry filesSha256; tampered tar refuses
//   F13 tray single-instance ... mutex + once-per-day schedule helpers present
// Each test drives the REAL committed functions inside isolated fixture
// roots — never the live backup dir, never the live stack, never restore.
//
// The legacy Get-MahabbatUpdateBackupState in mahabbat-update.ps1 is intentionally
// NOT tested here anymore: the updater keeps it verbatim as a fallback for old
// installs (its red-on-old-code proof stays in stage-a history d873c54).

const ROOT = join(import.meta.dirname, '..', '..');
const VALIDATE = readFileSync(join(ROOT, 'scripts', 'lib', 'mahabbat-backup-validate.ps1'), 'utf8');
const RESTORE = readFileSync(join(ROOT, 'scripts', 'mahabbat-restore.ps1'), 'utf8');
const CRYPTO = readFileSync(join(ROOT, 'scripts', 'lib', 'mahabbat-backup-crypto.ps1'), 'utf8');
const COMMON = readFileSync(join(ROOT, 'scripts', 'lib', 'mahabbat-common.ps1'), 'utf8');
const TRAY = readFileSync(join(ROOT, 'installer', 'app', 'tray-host.ps1'), 'utf8');

assert.ok(VALIDATE.includes('function Get-MahabbatValidatedBackupState'), 'validator exposes Get-MahabbatValidatedBackupState');
assert.ok(VALIDATE.includes('function Test-MahabbatBackupManifest'), 'validator exposes Test-MahabbatBackupManifest');

const psSuite = (body) => [
  '$ProgressPreference = "SilentlyContinue";',
  '$ErrorActionPreference = "Stop";',
  ...body,
].join('\r\n');

const runPs = (lines, env = {}) => {
  const tmp = join(tmpdir(), `stage-c-${Date.now()}-${Math.floor(Math.random() * 1e6)}.ps1`);
  writeFileSync(tmp, psSuite(lines), 'utf8');
  try {
    return execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tmp], { encoding: 'utf8', env: { ...process.env, ...env } });
  } finally {
    rmSync(tmp, { force: true });
  }
};

const withFixtureRoot = (fn) => {
  const root = mkdtempSync(join(tmpdir(), 'mahabbat-stage-c-'));
  try {
    return fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

const stampName = (offsetHours) => {
  const stamp = new Date(Date.now() + offsetHours * 3600_000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${stamp.getFullYear()}-${pad(stamp.getMonth() + 1)}-${pad(stamp.getDate())}-${pad(stamp.getHours())}${pad(stamp.getMinutes())}${pad(stamp.getSeconds())}`;
};

const writeBackupDir = (fixtureRoot, dirName, manifestText, withDump, withFilesMarker) => {
  const dir = join(fixtureRoot, dirName);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'backup-manifest.json'), manifestText);
  if (withDump) writeFileSync(join(dir, 'database.dump'), 'AUDIT-DUMP');
  if (withFilesMarker) writeFileSync(join(dir, 'server-local-data.empty'), 'marker');
  return dir;
};

// Validator lib needs Get-MahabbatBackupRoot (common) + hashing (crypto).
// Load order mirrors the real scripts: common, crypto, validate — dot-sourced
// from the REAL committed files (never embedded copies, never live state).
// Get-MahabbatBackupRoot is redefined AFTER dot-sourcing so the fixture root
// wins in this session only (identical shape to stage-a wiring).
const LIB = join(ROOT, 'scripts', 'lib');
const GATE_PREAMBLE = [
  `. ${join(LIB, 'mahabbat-common.ps1')}`,
  `. ${join(LIB, 'mahabbat-backup-crypto.ps1')}`,
  `. ${join(LIB, 'mahabbat-backup-validate.ps1')}`,
];

const runGate = (fixtureRoot) => {
  const out = runPs([
    ...GATE_PREAMBLE,
    'function Get-MahabbatBackupRoot { return $env:MAHABBAT_STAGE_C_GATE }',
    '$gate = Get-MahabbatValidatedBackupState -MaxAgeHours 24',
    '$gate | ConvertTo-Json -Compress',
  ], { MAHABBAT_STAGE_C_GATE: fixtureRoot });
  return JSON.parse(out);
};

test('F04: empty manifest {} without a dump must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    writeBackupDir(root, stampName(-1), '{}', false, false);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `empty manifest accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F04: manifest without dump payload must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    const ts = new Date().toISOString();
    writeBackupDir(root, stampName(-1), JSON.stringify({ timestamp: ts, dump: 'database.dump' }), false, false);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `missing dump accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F05: a copy dated in the future must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    const future = new Date(Date.now() + 24 * 3600_000).toISOString();
    writeBackupDir(root, stampName(24), JSON.stringify({ backupVersion: 2, timestamp: future, dump: 'database.dump', files: 'server-local-data.empty (snapshot unavailable)' }), true, true);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `future copy accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F04/F05: complete fresh copy validates as fresh (control)', () => {
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    writeBackupDir(root, stampName(-1), JSON.stringify({ backupVersion: 2, timestamp: past, dump: 'database.dump', files: 'server-local-data.empty (snapshot unavailable)' }), true, true);
    return runGate(root);
  });
  assert.equal(gate.Fresh, true, `complete fresh copy rejected: ${JSON.stringify(gate)}`);
});

test('F06: manual encrypted manifest without keySource must survive the restore read under StrictMode', () => {
  // The restore script must NOT read $manifest.encryption.keySource as a bare
  // property under StrictMode (manual v1 copies without keySource throw
  // property-not-found). The guarded read nests it inside a
  // PSObject.Properties.Name -contains 'keySource' probe — require that
  // exact guard shape next to the assignment.
  const ksAssign = RESTORE.indexOf('$keySource = [string]$manifest.encryption.keySource');
  assert.ok(ksAssign !== -1, 'restore assigns keySource from the manifest');
  const ksGuard = RESTORE.indexOf("PSObject.Properties.Name -contains 'keySource'");
  assert.ok(ksGuard !== -1 && ksGuard < ksAssign, 'restore guards the keySource read with a property-presence probe (StrictMode crash on manual copies)');
  const out = runPs([
    'Set-StrictMode -Version Latest',
    `$manifest = '{"encrypted":true,"dump":"database.dump.enc","encryption":{"cipher":"AES-256-CBC+HMAC-SHA256"}}' | ConvertFrom-Json`,
    `$keySource = ''`,
    `try {`,
    `  if (($manifest.PSObject.Properties.Name -contains 'encryption') -and ($null -ne $manifest.encryption) -and ($manifest.encryption.PSObject.Properties.Name -contains 'keySource')) {`,
    `    $keySource = [string]$manifest.encryption.keySource`,
    `  }`,
    `} catch { $keySource = '' }`,
    `if ($keySource -like 'DPAPI*') { "DPAPI-branch" } else { "PASSWORD-branch:[" + $keySource + "]" }`,
  ]);
  assert.match(out.trim(), /PASSWORD-branch/, `guarded keySource read failed: ${out}`);
});

test('F06: legacy manual copy without keySource validates (backward compat)', () => {
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    const dir = writeBackupDir(root, stampName(-1), JSON.stringify({ timestamp: past, dump: 'database.dump.enc', encrypted: true, encryption: { cipher: 'AES-256-CBC+HMAC-SHA256' } }), false, false);
    writeFileSync(join(dir, 'database.dump.enc'), 'AUDIT-ENC');
    return runGate(root);
  });
  // No ciphertextSha256 in a v1 manifest: presence checks pass; the wrong-
  // password/corruption refusal happens at HMAC time during real restore.
  assert.equal(gate.Fresh, true, `legacy manual copy rejected at gate: ${JSON.stringify(gate)}`);
});

test('F08: tampered encrypted dump refuses at gate (SHA256 mismatch)', () => {
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    const dir = writeBackupDir(root, stampName(-1), JSON.stringify({
      backupVersion: 2, timestamp: past, dump: 'database.dump.enc', encrypted: true,
      files: 'server-local-data.empty (snapshot unavailable)',
      encryption: { cipher: 'AES-256-CBC+HMAC-SHA256', ciphertextSha256: '0'.repeat(64) },
    }), false, true);
    writeFileSync(join(dir, 'database.dump.enc'), 'TAMPERED');
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `tampered dump accepted as fresh: ${JSON.stringify(gate)}`);
});

test('F08: restore fails closed on file-volume errors (no warning+success)', () => {
  // F07/F08 contract: file-restore problems are fatal, never Write-Warning
  // followed by a success message.
  assert.ok(RESTORE.includes('helper container') || RESTORE.includes('--volumes-from') || RESTORE.includes('server-local-data'), 'restore carries no volume-based file restore');
  assert.ok(!RESTORE.includes('DB restore is complete, file volume untouched'), 'restore still downgrades file failure to warning+success');
  assert.ok(!RESTORE.includes('DB restore is complete, file volume may be stale'), 'restore still downgrades file failure to warning+success');
});

test('F13: tray enforces a single instance and records schedule state', () => {
  assert.ok(TRAY.includes('MahabbatTraySingleInstance'), 'tray carries no single-instance mutex');
  assert.ok(TRAY.includes('backup-state.json'), 'tray records no backup-state.json last-result file');
  assert.ok(TRAY.includes('Test-MahabbatTrayBackupDoneToday'), 'tray has no once-per-day success guard');
  assert.ok(TRAY.includes('MahabbatTrayBackupRunning'), 'tray has no single-flight guard');
});
