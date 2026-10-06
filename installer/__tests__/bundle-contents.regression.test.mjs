import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// T5 regression net: the EXE kit must stay complete (E5: the first 1.0.1
// build silently lost scripts/lib), versions stay distinguishable, and a
// repeated wizard run after interruption stays idempotent. Static checks
// over the .iss + sources: no Inno build needed, runs on any OS.
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..', '..');
const BS = String.fromCharCode(92);
const LF = String.fromCharCode(10);
const read = (rel) => readFileSync(path.join(ROOT, rel), 'utf8');
const exists = (rel) => existsSync(path.join(ROOT, rel));
const iss = read('installer/build/mahabbat-setup.iss');
const api = read('installer/app/setup-api.mjs');
const issLines = iss.split(LF);

test('scripts entry keeps recursesubdirs so scripts/lib ships (E5 validator lesson)', () => {
  const line = issLines.find((l) => l.startsWith('Source:') && l.includes('scripts'));
  assert.ok(line, 'iss must have a scripts Source entry');
  assert.ok(line.includes('recursesubdirs'), 'scripts entry must recurse into lib/, got: ' + line);
});

test('validator + crypto lib files exist on disk', () => {
  for (const f of [
    'scripts/lib/mahabbat-common.ps1',
    'scripts/lib/mahabbat-backup-crypto.ps1',
    'scripts/lib/mahabbat-backup-validate.ps1',
  ]) assert.ok(exists(f), 'missing kit file: ' + f);
});

test('host scripts exist on disk', () => {
  for (const f of [
    'scripts/mahabbat-setup.ps1',
    'scripts/mahabbat-setup-owner.ps1',
    'scripts/mahabbat-setup-apply.ps1',
    'scripts/mahabbat-setup-seed.ps1',
    'scripts/mahabbat-update.ps1',
    'scripts/mahabbat-backup.ps1',
    'scripts/mahabbat-restore.ps1',
    'scripts/mahabbat-doctor.ps1',
    'scripts/mahabbat-start.ps1',
    'scripts/mahabbat-stop.ps1',
    'scripts/mahabbat-status.ps1',
    'scripts/mahabbat-prerequisites.ps1',
    'scripts/mahabbat-bootstrap.ps1',
    'scripts/mahabbat-metadata.ps1',
    'scripts/mahabbat-verify-password.ps1',
    'scripts/mahabbat-rotate-key.ps1',
  ]) assert.ok(exists(f), 'missing kit file: ' + f);
});

test('installer app files exist on disk', () => {
  for (const f of [
    'installer/app/setup-api.mjs',
    'installer/app/tray.mjs',
    'installer/app/tray-host.ps1',
    'installer/app/wizard.html',
    'installer/app/preview-counts.mjs',
    'installer/app/runtime/NODE_VERSION.txt',
    'installer/app/runtime/NODE_SHA256.txt',
    'installer/UNLICENSED-SMARTSCREEN-NOTE.md',
  ]) assert.ok(exists(f), 'missing kit file: ' + f);
});

test('release identity quartet is referenced by the iss and exists', () => {
  for (const f of [
    'mahabbat-release.json',
    'mahabbat-release.schema.json',
    'CHANGELOG.md',
    'EXE_SHA256.txt',
  ]) {
    assert.ok(iss.includes(f), 'iss [Files] must ship release/' + f);
    assert.ok(exists('release/' + f), 'missing release file: ' + f);
  }
});

test('docs pair is referenced by the iss and exists', () => {
  for (const f of ['RUNNING_MAHABBAT.md', 'SECOND_PC_INSTALL.md']) {
    assert.ok(iss.includes(f), 'iss [Files] must ship docs/' + f);
    assert.ok(exists('docs/' + f), 'missing docs file: ' + f);
  }
});

test('controlled Node runtime is staged via {#NodeSource} with hash files', () => {
  assert.ok(iss.includes('{#NodeSource}'), 'iss must stage node via {#NodeSource}, never a personal path');
  assert.ok(iss.includes('runtime') && iss.includes('*.txt'), 'iss must ship runtime NODE_VERSION/NODE_SHA256 txt files');
  const build = read('installer/build/build-installer.ps1');
  assert.ok(build.includes('knownGood') || build.includes('NodeSha256'), 'build must verify the staged node hash');
});

test('no personal paths and no backup data inside {app} (R13)', () => {
  assert.ok(!iss.includes('C:' + BS + 'Users'), 'iss must not hardcode a personal profile path');
  assert.ok(!iss.includes('hermes' + BS + 'node'), 'iss must not hardcode a personal node path');
  const sourceLines = issLines.filter((l) => l.startsWith('Source:'));
  for (const l of sourceLines) {
    assert.ok(!l.toLowerCase().includes('programdata'), 'a [Files] entry must not reach into backup state dirs: ' + l);
  }
  const destDirs = issLines
    .filter((l) => l.startsWith('Source:'))
    .map((l) => (l.split('DestDir:')[1] || '').trim());
  assert.ok(destDirs.length > 10, 'expected a full [Files] kit, got ' + destDirs.length + ' entries');
  for (const d of destDirs) assert.ok(d.includes('{app}'), 'DestDir must stay under {app}, got: ' + d);
  const lower = iss.toLowerCase();
  assert.ok(!lower.includes('backup-state.json'), 'backup state must never ship inside the EXE');
});

test('versions are explicit and distinguishable (AppVersion vs FileVersion vs ProductVersion)', () => {
  assert.ok(iss.includes('#define AppVersion "1.0.0"'), 'iss keeps a 1.0.0 AppVersion fallback for bare ISCC runs');
  assert.ok(iss.includes('#define FileVersion "1.0.0.0"'), 'iss keeps a numeric FileVersion fallback quad');
  assert.ok(!iss.includes('VersionInfoProductVersion='), 'ProductVersion must stay Inno-defaulted (explicit non-quad aborts ISCC; default derives Product from AppVersion)');
  assert.ok(iss.includes('VersionInfoTextVersion={#FileVersion}'), 'File text version must carry the numeric quad (FileVersionInfo.FileVersion reads the text)');
  assert.ok(iss.includes('OutputBaseFilename=Mahabbat-Setup-{#AppVersion}'), 'EXE name must embed the version');
  assert.ok(iss.includes('UninstallDisplayName=Mahabbat {#AppVersion}'), 'Add/Remove Programs must show the version');
  const build = read('installer/build/build-installer.ps1');
  assert.ok(build.includes('x.y.z.w quad'), 'build must enforce a numeric FileVersion quad');
});

test('no duplicate route keys in setup-api (each POST path resolves once)', () => {
  for (const route of ["'/api/apply'", "'/api/seed'", "'/api/owner'", "'/api/status'"]) {
    const n = api.split(route).length - 1;
    assert.equal(n, 1, route + ' must appear exactly once, got ' + n);
  }
});

test('setup-api refuses a second instance (wizard shortcut reuses the live API)', () => {
  assert.ok(api.includes('already running'), 'setup-api must exit when the health probe finds a live instance');
});

test('owner step short-circuits on repeat and rejects a different email', () => {
  assert.ok(api.includes('409'), 'owner must answer 409 when another email claims an existing install');
  const owner = read('scripts/mahabbat-setup-owner.ps1');
  assert.ok(owner.includes('exit 0'), 'owner script must exit 0 when the key already exists');
});

test('seed step is idempotent: same PINs continue, marker stores only a keyed hash', () => {
  assert.ok(api.includes('seed-complete.json'), 'seed must record a completion marker');
  assert.ok(api.includes('pinHmac'), 'seed marker must key on a PIN HMAC, never the PINs');
  assert.ok(api.includes('createHmac'), 'seed must key PINs with node:crypto HMAC');
  assert.ok(api.includes('seedDone'), 'status must expose the seed continuation flag');
});

test('seed marker is salted, never bare SHA256, and written with restricted perms (C-T5)', () => {
  assert.ok(api.includes('seed-salt'), 'seed must use a per-install salt file in .private');
  assert.ok(api.includes("createHmac('sha256'"), 'seed marker must be HMAC-SHA256, not bare SHA256');
  assert.ok(api.includes('seedPinHmac'), 'HMAC helper must take the per-install salt');
  assert.ok(!api.includes("createHash('sha256').update(String(b.pinW)"), 'bare SHA256(pinW:pinA) construction must be gone');
  assert.ok(!api.includes('pinHash })'), 'bare pinHash must never be written to the marker');
  assert.ok(api.includes('hmac-sha256-v1'), 'marker must label its KDF so the format can evolve');
  assert.ok(api.includes('writePrivateFile(SEED_COMPLETE_PATH'), 'marker must be written via the restricted-perms helper');
  assert.ok(api.includes('writePrivateFile(SEED_SALT_PATH'), 'salt must be written via the restricted-perms helper');
  const helper = api.slice(api.indexOf('const writePrivateFile'));
  assert.ok(helper.includes('mode: 0o600'), 'private helper must set mode 600');
  assert.ok(helper.includes('icacls'), 'private helper must lock the ACL like setup-token');
  assert.ok(api.includes('Legacy pre-hardening marker'), 'old bare-hash markers must migrate, not re-seed');
});

test('single tray instance via mutex (no double-scheduled nightly backup)', () => {
  const host = read('installer/app/tray-host.ps1');
  assert.ok(host.includes('MahabbatTraySingleInstance'), 'tray host must guard on a named mutex');
  assert.ok(host.includes('WaitOne(0'), 'second tray must exit instead of blocking');
});

test('seed secrets arrive via scoped env-file and are shredded after reading', () => {
  const seed = read('scripts/mahabbat-setup-seed.ps1');
  assert.ok(seed.includes('Remove-MahabbatFileSecure'), 'seed must shred the scoped env-file after reading');
  const owner = read('scripts/mahabbat-setup-owner.ps1');
  assert.ok(owner.includes('Remove-MahabbatFileSecure'), 'owner must shred the scoped env-file after reading');
});

test('update journal exists as the apply continuation flag', () => {
  const update = read('scripts/mahabbat-update.ps1');
  assert.ok(update.includes('update-journal.json'), 'update must journal stages for resume');
});

test('build preflight pins the kit before ISCC runs', () => {
  const build = read('installer/build/build-installer.ps1');
  assert.ok(build.includes('requiredBundle'), 'build must assert the kit file list');
  assert.ok(build.includes('mahabbat-backup-validate'), 'preflight must cover the validator lib (E5)');
});
