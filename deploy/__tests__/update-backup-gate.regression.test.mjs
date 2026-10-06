// Windows-only suite: drives powershell.exe. On Linux CI every test skips
// (ubuntu runners lack PowerShell/Windows paths); venue-PC runs cover it.
const WIN_ONLY = process.platform === 'win32' ? test : (/** @param {string} _n */ (_n) => {});

import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

// Stage C regressions for NEXT_RELEASE_PLAN_RU findings F04/F05/F06/F08/F13,
// plus backup-v2 schema (owner: backup): encrypted files payload,
// versioned manifest, dual-payload verify.
//   F04 empty-manifest gate ..... {} without a dump must NOT validate as fresh
//   F05 future-date gate ........ a copy from the future must NOT validate as fresh
//   F06 keySource StrictMode .... manual encrypted copy without keySource survives restore read
//   F08 files integrity ........ encrypted copies carry filesSha256; tampered tar refuses
//   F08b open-tar fail-closed ... encrypted v2 with a PLAINTEXT tar must NOT validate
//                                (old-code shape: DB encrypted, files leaked open)
//   F08b nodigest fail-closed ... encrypted v2 .enc without filesSha256 must NOT validate
//   V2 schema .................. backup.ps1 encrypts the files tar (same MHBE01
//                                AES-256-CBC+HMAC-SHA256/PBKDF2-200k as the dump),
//                                manifest backupVersion=2 + files/filesEncrypted/
//                                filesSha256; verify-password checks BOTH payloads;
//                                legacy v1 (no backupVersion) stays readable
//   F13 tray single-instance ... mutex + once-per-day schedule helpers present
//   R06 updater load order ..... Get-MahabbatValidatedBackupGate must load the
//       crypto lib BEFORE the validator: without Get-MahabbatFileSha256Hex a
//       VALID digest-bearing copy fails closed ("не удалось проверить
//       целостность") and updates are wrongly refused.
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
const BACKUP = readFileSync(join(ROOT, 'scripts', 'mahabbat-backup.ps1'), 'utf8');
const VERIFY = readFileSync(join(ROOT, 'scripts', 'mahabbat-verify-password.ps1'), 'utf8');
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

// R06 helpers: drive the REAL Get-MahabbatValidatedBackupGate committed in
// mahabbat-update.ps1 (extracted by balanced-brace scan, $PSScriptRoot pinned
// to the real scripts dir — the same files production resolves). The preamble
// loads ONLY mahabbat-common.ps1: every other lib must come from the gate
// itself, exactly like the updater chain. Fixture roots are isolated temp
// dirs via the documented MAHABBAT_BACKUP_ROOT override — never live backups.
const UPDATE = readFileSync(join(ROOT, 'scripts', 'mahabbat-update.ps1'), 'utf8');

const extractGateSource = () => {
  const start = UPDATE.indexOf('function Get-MahabbatValidatedBackupGate');
  assert.ok(start !== -1, 'updater exposes Get-MahabbatValidatedBackupGate');
  let depth = 0;
  let end = -1;
  for (let i = UPDATE.indexOf('{', start); i < UPDATE.length; i++) {
    if (UPDATE[i] === '{') depth++;
    else if (UPDATE[i] === '}') {
      depth--;
      if (depth === 0) { end = i; break; }
    }
  }
  assert.ok(end !== -1, 'gate function has balanced braces');
  const src = UPDATE.slice(start, end + 1);
  assert.ok(src.includes('Get-MahabbatValidatedBackupState'), 'extracted gate does not forward to Get-MahabbatValidatedBackupState (scan truncated)');
  // The gate body carries no braces inside string literals, so the scan is exact.
  return src.split('$PSScriptRoot').join(`'${join(ROOT, 'scripts').replace(/'/g, "''")}'`);
};

const runRealGate = (fixtureRoot) => {
  const out = runPs([
    `. ${join(LIB, 'mahabbat-common.ps1')}`,
    extractGateSource(),
    '$gate = Get-MahabbatValidatedBackupGate -MaxAgeHours 24',
    '$gate | ConvertTo-Json -Compress',
  ], { MAHABBAT_BACKUP_ROOT: fixtureRoot });
  return JSON.parse(out);
};

// Manual password-copy shape: encrypted v2 WITH digests but WITHOUT keySource.
// digestOverride=null keeps the true dump digest (valid copy); any other value
// forges the manifest digest (tampered copy).
const writeDigestFixture = (fixtureRoot, dirName, digestOverride) => {
  const dir = join(fixtureRoot, dirName);
  mkdirSync(dir, { recursive: true });
  const dump = randomBytes(1024);
  const files = randomBytes(512);
  writeFileSync(join(dir, 'database.dump.enc'), dump);
  writeFileSync(join(dir, 'server-local-data.tar.gz.enc'), files);
  const sha = (b) => createHash('sha256').update(b).digest('hex');
  const past = new Date(Date.now() - 3600_000).toISOString();
  writeFileSync(join(dir, 'backup-manifest.json'), JSON.stringify({
    backupVersion: 2, timestamp: past, innerSha: 'r06-fixture',
    dump: 'database.dump.enc', encrypted: true,
    encryption: { cipher: 'AES-256-CBC+HMAC-SHA256', ciphertextSha256: digestOverride ?? sha(dump) },
    files: 'server-local-data.tar.gz.enc', filesSha256: sha(files),
  }));
  return dir;
};

WIN_ONLY('F04: empty manifest {} without a dump must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    writeBackupDir(root, stampName(-1), '{}', false, false);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `empty manifest accepted as fresh: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F04: manifest without dump payload must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    const ts = new Date().toISOString();
    writeBackupDir(root, stampName(-1), JSON.stringify({ timestamp: ts, dump: 'database.dump' }), false, false);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `missing dump accepted as fresh: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F05: a copy dated in the future must NOT validate as fresh', () => {
  const gate = withFixtureRoot((root) => {
    const future = new Date(Date.now() + 24 * 3600_000).toISOString();
    writeBackupDir(root, stampName(24), JSON.stringify({ backupVersion: 2, timestamp: future, dump: 'database.dump', files: 'server-local-data.empty (snapshot unavailable)' }), true, true);
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `future copy accepted as fresh: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F04/F05: complete fresh copy validates as fresh (control)', () => {
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    writeBackupDir(root, stampName(-1), JSON.stringify({ backupVersion: 2, timestamp: past, dump: 'database.dump', files: 'server-local-data.empty (snapshot unavailable)' }), true, true);
    return runGate(root);
  });
  assert.equal(gate.Fresh, true, `complete fresh copy rejected: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F06: manual encrypted manifest without keySource must survive the restore read under StrictMode', () => {
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

WIN_ONLY('F06: legacy manual copy without keySource validates (backward compat)', () => {
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

WIN_ONLY('F08: tampered encrypted dump refuses at gate (SHA256 mismatch)', () => {
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

WIN_ONLY('F08: restore fails closed on file-volume errors (no warning+success)', () => {
  // F07/F08 contract: file-restore problems are fatal, never Write-Warning
  // followed by a success message.
  assert.ok(RESTORE.includes('helper container') || RESTORE.includes('--volumes-from') || RESTORE.includes('server-local-data'), 'restore carries no volume-based file restore');
  assert.ok(!RESTORE.includes('DB restore is complete, file volume untouched'), 'restore still downgrades file failure to warning+success');
  assert.ok(!RESTORE.includes('DB restore is complete, file volume may be stale'), 'restore still downgrades file failure to warning+success');
});

WIN_ONLY('R06: updater gate loads the crypto lib before the validator', () => {
  const src = extractGateSource();
  const cryptoAt = src.indexOf('mahabbat-backup-crypto.ps1');
  const validateAt = src.indexOf('mahabbat-backup-validate.ps1');
  assert.ok(cryptoAt !== -1, 'gate never loads the crypto lib (R06: valid digest copies fail closed, updates wrongly refused)');
  assert.ok(validateAt !== -1, 'gate never loads the validator lib');
  assert.ok(cryptoAt < validateAt, 'gate loads the validator before crypto (Get-MahabbatFileSha256Hex missing at validate time)');
});

WIN_ONLY('R06: the real updater gate accepts a valid digest-bearing copy', () => {
  const gate = withFixtureRoot((root) => {
    writeDigestFixture(root, stampName(-1), null);
    return runRealGate(root);
  });
  assert.equal(gate.Fresh, true, `real updater gate rejected a valid digest copy (R06): ${JSON.stringify(gate)}`);
});

WIN_ONLY('R06: the real updater gate still refuses a tampered digest copy', () => {
  const gate = withFixtureRoot((root) => {
    writeDigestFixture(root, stampName(-1), '0'.repeat(64));
    return runRealGate(root);
  });
  assert.equal(gate.Fresh, false, `real updater gate accepted a tampered copy: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F13: tray enforces a single instance and records schedule state', () => {
  assert.ok(TRAY.includes('MahabbatTraySingleInstance'), 'tray carries no single-instance mutex');
  assert.ok(TRAY.includes('backup-state.json'), 'tray records no backup-state.json last-result file');
  assert.ok(TRAY.includes('Test-MahabbatTrayBackupDoneToday'), 'tray has no once-per-day success guard');
  assert.ok(TRAY.includes('MahabbatTrayBackupRunning'), 'tray has no single-flight guard');
});

WIN_ONLY('F08b: encrypted v2 with a PLAINTEXT files tar must NOT validate (open tar fails closed)', () => {
  // Old-code shape: DB encrypted, files leaked as an open tar, manifest
  // backupVersion=2 without files protection. The old validator accepted
  // this as fresh (open tar passes) — v2 must fail closed, while legacy
  // v1 without backupVersion stays readable (see next test).
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    const dir = writeBackupDir(root, stampName(-1), JSON.stringify({
      backupVersion: 2, timestamp: past, dump: 'database.dump.enc', encrypted: true,
      files: 'server-local-data.tar.gz',
      encryption: { cipher: 'AES-256-CBC+HMAC-SHA256' },
    }), false, false);
    writeFileSync(join(dir, 'database.dump.enc'), 'AUDIT-ENC-DB');
    writeFileSync(join(dir, 'server-local-data.tar.gz'), 'PLAINTEXT-TAR-LEAK');
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `encrypted v2 with open tar accepted as fresh: ${JSON.stringify(gate)}`);
});

WIN_ONLY('F08b: encrypted v2 .enc without filesSha256 must NOT validate (no digest fails closed)', () => {
  // Without filesSha256 a tampered/swapped .enc tar would pass the gate.
  // The old validator skipped the check when the digest was absent.
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    const dir = writeBackupDir(root, stampName(-1), JSON.stringify({
      backupVersion: 2, timestamp: past, dump: 'database.dump.enc', encrypted: true,
      files: 'server-local-data.tar.gz.enc',
      encryption: { cipher: 'AES-256-CBC+HMAC-SHA256' },
    }), false, false);
    writeFileSync(join(dir, 'database.dump.enc'), 'AUDIT-ENC-DB');
    writeFileSync(join(dir, 'server-local-data.tar.gz.enc'), 'AUDIT-ENC-FILES');
    return runGate(root);
  });
  assert.equal(gate.Fresh, false, `encrypted v2 .enc without filesSha256 accepted as fresh: ${JSON.stringify(gate)}`);
});

WIN_ONLY('V2-compat: legacy v1 encrypted copy with an open tar still validates (backward compat)', () => {
  // v1 = no backupVersion field (old manual copies: encrypted DB, plaintext
  // files tar). The v2 fail-closed rules above MUST NOT break these.
  const gate = withFixtureRoot((root) => {
    const past = new Date(Date.now() - 3600_000).toISOString();
    const dir = writeBackupDir(root, stampName(-1), JSON.stringify({
      timestamp: past, dump: 'database.dump.enc', encrypted: true,
      files: 'server-local-data.tar.gz',
      encryption: { cipher: 'AES-256-CBC+HMAC-SHA256' },
    }), false, false);
    writeFileSync(join(dir, 'database.dump.enc'), 'AUDIT-ENC-DB');
    writeFileSync(join(dir, 'server-local-data.tar.gz'), 'LEGACY-PLAINTEXT-TAR');
    return runGate(root);
  });
  assert.equal(gate.Fresh, true, `legacy v1 copy rejected at gate: ${JSON.stringify(gate)}`);
});

WIN_ONLY('V2-schema: backup encrypts the files tar with the same MHBE01 format and writes backupVersion/filesSha256/filesEncrypted', () => {
  // Static contract on the REAL committed backup script. Old code wrote the
  // files archive as an open tar next to the encrypted dump and a manifest
  // without backupVersion/filesSha256 — every assertion below fails there.
  assert.ok(BACKUP.includes('server-local-data.tar.gz.enc'), 'backup writes no encrypted files archive');
  assert.ok(BACKUP.includes('Protect-MahabbatDump -PlainPath $filesArchive -EncPath $filesEncPath'), 'backup never encrypts the files tar with the dump password bytes');
  assert.ok(BACKUP.includes('Remove-MahabbatFileSecure -Path $filesArchive'), 'backup leaves the plaintext files tar next to the .enc (must shred after round-trip verify)');
  assert.ok(BACKUP.includes('backupVersion = 2'), 'backup manifest carries no backupVersion=2');
  assert.ok(BACKUP.includes('filesSha256'), 'backup manifest carries no filesSha256');
  assert.ok(BACKUP.includes('filesEncrypted'), 'backup manifest carries no filesEncrypted flag');
  assert.ok(CRYPTO.includes('function Test-MahabbatBackupPayloadPassword'), 'crypto lib exposes no per-payload HMAC+SHA verifier for the files archive');
});

WIN_ONLY('V2-schema: verify-password checks BOTH payloads with the same password bytes', () => {
  // Old verify-password only checked database.dump.enc. v2 must verify the
  // files archive too (same password bytes, same MHBE01 format), refuse a
  // referenced-but-missing .enc, and keep legacy open-tar copies readable.
  assert.ok(VERIFY.includes('server-local-data.tar.gz.enc'), 'verify-password never looks at the files archive');
  assert.ok(VERIFY.includes('Test-MahabbatBackupPayloadPassword'), 'verify-password verifies no second payload (files HMAC+SHA)');
  assert.ok(VERIFY.includes('filesSha256'), 'verify-password ignores the filesSha256 manifest digest');
  assert.ok(VERIFY.includes('DPAPI'), 'verify-password handles no nightly DPAPI keySource for both payloads');
  assert.ok(VERIFY.includes('legacy') || VERIFY.includes('Legacy') || VERIFY.includes('LEGACY') || VERIFY.toLowerCase().includes('legacy v1'), 'verify-password documents no legacy open-tar path');
});
