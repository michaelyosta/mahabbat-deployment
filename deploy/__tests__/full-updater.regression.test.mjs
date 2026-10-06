// Stage D regression: full updater contract (F03/F11/F12) — pinned check→apply.
// Static (CI-safe, no docker/registry/live install) + Windows-only behavioral
// dry-runs on an isolated fixture root (MAHABBAT_DEPLOY_ROOT override —
// never the live install, never the live backup dir):
//   F03 full-kit apply .. apply covers host/locks/inner/images/metadata/reconcile/verify, not images-only
//   F11 check→apply .... check records a pinned target (record schema 1:
//                        per-image digests + manifest SHA + locks SHAs);
//                        apply installs EXACTLY it (repo@digest pull, digest
//                        refs for up, post-pull verify) and refuses on drift
//   F12 rollback/resume  every apply stage journals state; rollback covers tags+restart and names restore;
//                        rollback runs ONLY after the maintenance window opened
//   G6 pre-gate ......... gate refusal (stale window/backup/locks/pin) changes
//                        no runtime: strict gate→mutation ordering + refusal journal
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cpSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

const WIN_ONLY = process.platform === 'win32' ? test : (/** @param {string} _n */ (_n) => {});

const ROOT = join(import.meta.dirname, '..', '..');
const UPDATE = readFileSync(join(ROOT, 'scripts', 'mahabbat-update.ps1'), 'utf8');
const PINLIB = readFileSync(join(ROOT, 'scripts', 'lib', 'mahabbat-update-pin.ps1'), 'utf8');
const COMMON = readFileSync(join(ROOT, 'scripts', 'lib', 'mahabbat-common.ps1'), 'utf8');
const API = readFileSync(join(ROOT, 'installer', 'app', 'setup-api.mjs'), 'utf8');

const pos = (hay, needle) => {
  const i = hay.indexOf(needle);
  assert.ok(i !== -1, `expected marker: ${needle}`);
  return i;
};

test('F03: apply updates the full kit, not images alone', () => {
  for (const stage of [
    'backup-gate',
    'locks',
    'pin',
    'maintenance',
    'inner-checkout',
    'snapshots',
    'pull',
    'restart',
    'metadata-plan',
    'metadata-apply',
    'reconcile',
    'verify',
  ]) {
    assert.ok(UPDATE.includes(`'${stage}'`), `apply must journal stage ${stage}`);
  }
  assert.ok(UPDATE.includes('mahabbat-metadata.ps1'), 'apply must run metadata plan/apply');
  assert.ok(UPDATE.includes('Get-MahabbatReleaseManifest'), 'apply must read the release manifest');
  assert.ok(UPDATE.includes('Get-MahabbatImageDigestsLock'), 'apply must consult the digests lock');
  assert.ok(UPDATE.includes('Invoke-MahabbatDamagedTotalsReconcile'), 'apply must reconcile damaged totals');
  assert.ok(!UPDATE.includes('seed-venue'), 'apply must never seed over user data');
  assert.ok(UPDATE.includes('PIN'), 'reconcile must document PIN/price/owner preservation');
  assert.ok(
    UPDATE.includes('Test-MahabbatHostFilesHash') && UPDATE.includes('hostScriptsHash'),
    'verify must re-hash the installed host kit against release hostScriptsHash',
  );
});

test('F11: pinned target record carries digests + manifest/locks SHAs', () => {
  for (const fn of ['New-MahabbatUpdateTargetRecord', 'Write-MahabbatUpdateTargetRecord', 'Test-MahabbatUpdateTargetRecord']) {
    assert.ok(PINLIB.includes(`function ${fn}`), `pin lib must define ${fn}`);
  }
  for (const field of ['schema', 'manifestSha256', 'locksSha256', 'manifestDigests', 'targets', 'targetDigest', 'manifestDigest', 'checkedAt']) {
    assert.ok(PINLIB.includes(field), `pin record must carry ${field}`);
  }
  assert.ok(PINLIB.includes('image-digests.lock.json') && PINLIB.includes('mahabbat-inner.lock.json'), 'record must pin both locks SHAs');
  assert.ok(PINLIB.includes('branding') && PINLIB.includes('posGateway'), 'record must carry every release artifact digest');
  // check ALWAYS records (default .private/update-target.json), payload exposes it.
  assert.ok(UPDATE.includes('Write-MahabbatUpdateTargetRecord -Path $targetPath'), 'check must always write the pinned record');
  assert.ok(UPDATE.includes('Get-MahabbatUpdateDefaultTargetPath'), 'record defaults to .private/update-target.json');
  assert.ok(UPDATE.includes('PINNED_TARGET_FILE:'), 'check must print the record path');
  assert.ok(UPDATE.includes('targetFile') && UPDATE.includes('manifestSha256'), 'check -Json must expose targetFile + manifestSha256');
  // crypto lib (T2-owned) is loaded when present so SHAs/digests verify; never duplicated.
  assert.ok(UPDATE.includes('mahabbat-backup-crypto'), 'updater must load the backup crypto lib when present');
  assert.ok(PINLIB.includes('Get-MahabbatFileSha256Hex'), 'pin hashing must use the crypto lib helper when loaded');
});

test('F11: apply pulls EXACTLY the recorded digest, never a mutable alias', () => {
  assert.ok(UPDATE.includes('function Invoke-MahabbatPinnedImagePull'), 'apply must pull via the pinned-pull helper');
  assert.ok(UPDATE.includes('docker pull $ref') || UPDATE.includes('docker pull'), 'pinned pull must fetch repo@digest refs');
  assert.ok(UPDATE.includes('RepoDigests'), 'apply must verify the pulled image digest post-pull');
  assert.ok(UPDATE.includes('PULL OK'), 'pinned pull must log per-image proof');
  assert.ok(
    UPDATE.includes('MAHABBAT_TWENTY_IMAGE') && UPDATE.includes('MAHABBAT_POS_IMAGE'),
    'up must run on digest refs via image overrides',
  );
  assert.ok(UPDATE.includes('ALIAS SYNC'), 'local mutable alias must sync to the pinned image (no later downgrade)');
  assert.ok(!/Invoke-MahabbatCompose\s+@\(\s*'pull'\s*\)/.test(UPDATE), 'no bare compose pull of mutable aliases may remain');
  assert.ok(UPDATE.includes("@('pull', 'db', 'redis')"), 'infra pull stays scoped to digest-pinned db/redis');
  // drift refuses via the record test (manifest SHA, locks SHAs, per-image digests).
  assert.ok(UPDATE.includes('Test-MahabbatUpdateTargetRecord -Recorded $recorded'), 'apply must re-assert the whole record');
  assert.ok(UPDATE.includes("'pin' -State 'refused'"), 'pin drift must journal a refusal');
});

test('G6: pre-gate refusal precedes every runtime mutation, in order', () => {
  // Order WITHIN the apply flow only: the same markers also occur in helper
  // definitions (rollback/up, open/stop, close), which sit earlier in the file.
  const flowStart = UPDATE.indexOf('# Pre-gate: a stale maintenance window');
  assert.ok(flowStart !== -1, 'apply flow must open with the stale-window pre-gate');
  const flow = UPDATE.slice(flowStart);
  const staleRefuse = pos(flow, "'maintenance' -State 'refused'");
  const backupRefuse = pos(flow, "'backup-gate' -State 'refused'");
  const locksRefuse = pos(flow, "'locks' -State 'refused'");
  const pinRefuse = pos(flow, "'pin' -State 'refused'");
  const windowOpen = pos(flow, 'Open-MahabbatMaintenanceWindow -Release $release -RecordedTarget $recorded');
  const snapshots = pos(flow, "'snapshots' -State 'ok'");
  const pinnedPull = pos(flow, 'Invoke-MahabbatPinnedImagePull -Targets');
  const up = pos(flow, "@('up', '-d')");
  const windowClose = pos(flow, 'Close-MahabbatMaintenanceWindow');
  const order = [staleRefuse, backupRefuse, locksRefuse, pinRefuse, windowOpen, snapshots, pinnedPull, up, windowClose];
  assert.deepEqual([...order].sort((a, b) => a - b), order, 'gates → window → snapshots → pinned pull → up → close');
  // The POS write ban itself lives inside the window open (called after every gate).
  const openDef = pos(UPDATE, 'function Open-MahabbatMaintenanceWindow');
  const closeDef = pos(UPDATE, 'function Close-MahabbatMaintenanceWindow');
  const stopPos = pos(UPDATE, "'stop', 'pos-gateway'");
  assert.ok(stopPos > openDef && stopPos < closeDef, 'pos-gateway stop must live inside the window-open helper');
  assert.ok(
    flow.indexOf('Test-MahabbatMaintenanceOpen') < flow.indexOf('Assert-MahabbatDockerEngine'),
    'stale-window check must precede even the engine assert',
  );
  // rollback (tags + restart) runs ONLY after this run mutated runtime.
  assert.ok(UPDATE.includes('if ($windowOpened)'), 'rollback must be gated on the window this run opened');
  assert.ok(UPDATE.includes("'rollback' -State 'skipped'"), 'pre-window failure must journal rollback/skipped, not restart anything');
});

test('maintenance: POS write ban brackets the mutation, stale window refuses', () => {
  assert.ok(UPDATE.includes('function Open-MahabbatMaintenanceWindow'), 'window open helper must exist');
  assert.ok(UPDATE.includes('function Close-MahabbatMaintenanceWindow'), 'window close helper must exist');
  assert.ok(PINLIB.includes('function Test-MahabbatMaintenanceOpen'), 'stale-window probe must be testable');
  assert.ok(UPDATE.includes('maintenance.json'), 'window must be a flag file under .private');
  assert.ok(UPDATE.includes('Незакрытое окно обслуживания'), 'stale window must refuse with operator guidance');
  assert.ok(UPDATE.includes('pos-gateway не остановился') || UPDATE.includes('pos-gateway did not stop'), 'failed POS stop must refuse the update');
  assert.ok(UPDATE.includes('Remove-Item -LiteralPath $flag'), 'close must remove the flag');
});

test('common: running venue/pos images are judged by digest, not tag', () => {
  assert.ok(COMMON.includes('function Get-MahabbatReleaseImageDigests'), 'common must read expected digests from the release manifest');
  assert.ok(COMMON.includes('images.venue.digest') && COMMON.includes('images.posGateway.digest'), 'expected digests come from manifest artifacts');
  assert.ok(COMMON.includes('function Get-MahabbatContainerImageManifestDigest'), 'common must resolve the running image digest');
  assert.ok(COMMON.includes('image digest mismatch'), 'digest mismatch must fail even when the tag matches');
  assert.ok(COMMON.includes('image name mismatch'), 'legacy tag check stays as fallback for locally built images');
});

test('wizard API: check records the target file, apply requires it', () => {
  assert.ok(API.includes('UPDATE_TARGET_FILE'), 'API must define the shared target file path');
  assert.ok(API.includes("'-TargetFile', UPDATE_TARGET_FILE"), 'check AND apply must pass the same target file');
  assert.ok(API.includes('update-target.json'), 'target file lives under .private');
  assert.ok(API.includes('targetFile'), 'check response must surface the target file');
  assert.ok(API.includes('409'), 'apply without a check record must refuse before touching runtime');
  assert.ok(API.includes('Проверить обновления'), 'apply refusal must guide the operator back to check');
});

test('F12: every apply failure has a journaled rollback/resume path', () => {
  assert.ok(UPDATE.includes('Write-MahabbatUpdateJournalEntry'), 'stages must journal');
  assert.ok(UPDATE.includes('Invoke-MahabbatUpdateRollback -Reason $stageMsg'), 'apply must call rollback on failure');
  assert.ok(UPDATE.includes('return $restored'), 'rollback must report whether the previous version was RESTORED and healthy (not merely restarted)');
  assert.ok(!UPDATE.includes('tag "$repo:previous"') && !UPDATE.includes('inspect "$repo:previous"'), 'unbraced "$repo:previous" in a docker command expands to empty (scoped-variable parse) — snapshot/rollback refs must use ${repo}:previous');
  assert.ok(UPDATE.includes('Get-MahabbatImageRepoWithoutTag $ref'), 'rollback/snapshots must parse digest refs too');
  assert.ok(UPDATE.includes('mahabbat-restore.ps1'), 'rollback must name the data-restore path when data was touched');
  assert.ok(UPDATE.includes(':previous'), 'image rollback must use snapshots');
  assert.ok(UPDATE.includes('resume') || UPDATE.includes('Resume') || UPDATE.includes('повторите apply'), 'resume must be documented');
  assert.ok(UPDATE.includes('maintenance') || UPDATE.includes('MAINTENANCE'), 'maintenance window must bracket the mutation');
  assert.ok(UPDATE.includes('ban-holds'), 'write ban must be re-asserted after restart and after metadata recreate');
  assert.ok(UPDATE.includes('pos-start'), 'POS must start only after verify, with its own health gate');
  assert.ok(UPDATE.includes("-Exclude @('pos-gateway')"), 'pre-verify health gate must exclude the banned POS service');
  assert.ok(UPDATE.includes('RECONCILE DEFERRED'), 'deferred reconcile must never print OK');
  assert.ok(UPDATE.includes('Test-MahabbatMetadataPlanClean'), 'metadata delivery must be proven by a clean post-apply plan');
  assert.ok(!/\$\{[A-Za-z_][A-Za-z0-9_]*\./.test(UPDATE), 'no ${var.property} braced-dotted misuse (PowerShell reads it as a literal variable name, not a property)');
  assert.ok(UPDATE.includes('no mutable alias to retag onto'), 'rollback must handle digest-form refs via the lock mutable alias');
  assert.ok(UPDATE.includes('...[truncated]'), 'journal details must be length-capped');
  assert.ok(UPDATE.includes('Select-Object -Last 300'), 'journal must be a bounded ring');
  assert.ok(UPDATE.includes('quarantined to'), 'unreadable journal must be quarantined, never silently discarded');
  assert.ok(UPDATE.includes('No changes'), 'plan-clean must accept the explicit no-changes shape, not only the zero-count summary');
  assert.ok(!/Join-Path\s+[^\r\n]*'[^']*'\s+'[^']*'\s+'[^']*'/.test(UPDATE), 'no 3-positional Join-Path (PS 5.1 supports only 2; -AdditionalChildPath is PS6+)');
  assert.ok(UPDATE.includes('Get-Content -Raw -LiteralPath $path -ErrorAction Stop'), 'journal read must terminate on provider errors or quarantine never engages');
  assert.ok(COMMON.includes('PreUpdate'), 'digest gate must distinguish pre-update (names/pins) from post-update (digest equality)');
});

test('post-update verify covers versions/images/logic-functions/parity/health/invariants', () => {
  assert.ok(UPDATE.includes('Get-MahabbatUpdateVerifyReport'), 'verify report must exist');
  for (const probe of ['inner', 'images', 'logic-function', 'health']) {
    assert.ok(UPDATE.toLowerCase().includes(probe), `verify must probe ${probe}`);
  }
  assert.ok(API.includes('/api/update-verify'), 'wizard API must expose update-verify');
  const wizard = readFileSync(join(ROOT, 'installer', 'app', 'wizard.html'), 'utf8');
  assert.ok(wizard.includes('update-verify'), 'wizard must call update-verify after apply');
  assert.ok(wizard.includes('Mahabbat'), 'wizard must show the Mahabbat version, not Twenty');
});

// ---- Windows-only behavioral dry-runs (isolated fixture root, no live install) ----

const psSuite = (body) => [
  '$ProgressPreference = "SilentlyContinue";',
  '$ErrorActionPreference = "Stop";',
  ...body,
].join('\r\n');

const runPs = (lines, env = {}) => {
  const tmp = join(tmpdir(), `updater-t4-${Date.now()}-${Math.floor(Math.random() * 1e6)}.ps1`);
  writeFileSync(tmp, psSuite(lines), 'utf8');
  try {
    return execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tmp], {
      encoding: 'utf8',
      timeout: 90000,
      env: { ...process.env, ...env },
    });
  } finally {
    rmSync(tmp, { force: true });
  }
};

const sha256file = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
// PowerShell 5.1 Set-Content -Encoding UTF8 emits a BOM; the updater now
// writes BOM-less, but strip defensively for files from older runs.
const readJson = (p) => JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));

const withFixtureRoot = (fn) => {
  const root = mkdtempSync(join(tmpdir(), 'mahabbat-updater-t4-'));
  try {
    mkdirSync(join(root, '.private'), { recursive: true });
    mkdirSync(join(root, 'release'), { recursive: true });
    mkdirSync(join(root, 'empty-backups'), { recursive: true });
    cpSync(join(ROOT, 'release', 'mahabbat-release.json'), join(root, 'release', 'mahabbat-release.json'));
    cpSync(join(ROOT, 'image-digests.lock.json'), join(root, 'image-digests.lock.json'));
    cpSync(join(ROOT, 'mahabbat-inner.lock.json'), join(root, 'mahabbat-inner.lock.json'));
    writeFileSync(join(root, '.env'), 'MAHABBAT_IMAGE_OWNER=fixtureowner\n', 'utf8');
    return fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

const UPDATE_PS1 = join(ROOT, 'scripts', 'mahabbat-update.ps1');

WIN_ONLY('check dry-run writes a schema-1 pinned record (isolated root)', () => {
  withFixtureRoot((root) => {
    const target = join(root, '.private', 'update-target.json');
    const out = runPs(
      [`& '${UPDATE_PS1}' -Action check -Json -TargetFile '${target}'`],
      { MAHABBAT_DEPLOY_ROOT: root, MAHABBAT_BACKUP_ROOT: join(root, 'empty-backups') },
    );
    const payload = JSON.parse(out.trim().split(/\r?\n/).pop());
    assert.equal(payload.ok, true);
    assert.equal(payload.targetFile, target);
    const record = readJson(target);
    const manifest = readJson(join(root, 'release', 'mahabbat-release.json'));
    assert.equal(record.schema, 1);
    assert.equal(record.manifestSha256, sha256file(join(root, 'release', 'mahabbat-release.json')));
    assert.equal(record.locksSha256['image-digests.lock.json'], sha256file(join(root, 'image-digests.lock.json')));
    assert.equal(record.locksSha256['mahabbat-inner.lock.json'], sha256file(join(root, 'mahabbat-inner.lock.json')));
    assert.equal(record.manifestDigests.venue, manifest.images.venue.digest);
    assert.equal(record.manifestDigests.posGateway, manifest.images.posGateway.digest);
    assert.equal(record.manifestDigests.branding, manifest.images.branding.digest);
    const byKey = Object.fromEntries(record.targets.map((t) => [t.key, t]));
    // T3-final: enforced digests may be the TBD sentinel until CI publishes the
    // new immutable tags. The updater contract (F11) falls back to the live
    // remote digest on TBD, so the pinned target equals the remote digest —
    // '' when no registry is reachable — instead of the manifest value.
    for (const [key, img] of [['twenty', 'venue'], ['pos', 'posGateway']]) {
      if (manifest.images[img].digest === 'sha256:TBD-after-publish') {
        assert.equal(byKey[key].targetDigest, byKey[key].remoteDigest, `${key}: TBD manifest digest must pin the live remote digest`);
      } else {
        assert.equal(byKey[key].targetDigest, manifest.images[img].digest);
      }
    }
    assert.ok(!byKey.twenty.repo.includes(':') && !byKey.twenty.repo.includes('@'), 'repo must be tag-free');
  });
});

WIN_ONLY('record roundtrip: fresh pins pass, manifest drift refuses', () => {
  withFixtureRoot((root) => {
    const lib = join(ROOT, 'scripts', 'lib');
    const buildPinned = (manifestPath) => [
      `$manifest = Get-Content -Raw -LiteralPath '${manifestPath}' | ConvertFrom-Json`,
      '$pinned = [pscustomobject]@{ Release = $manifest; Rows = @(',
      `  [pscustomobject]@{ Key = 'twenty'; Image = 'ghcr.io/fixtureowner/mahabbat-twenty:v2.29.0-venue'; TargetDigest = [string]$manifest.images.venue.digest; RemoteDigest = '' },`,
      `  [pscustomobject]@{ Key = 'pos'; Image = 'ghcr.io/fixtureowner/mahabbat-pos-gateway:v2.29.0-venue'; TargetDigest = [string]$manifest.images.posGateway.digest; RemoteDigest = '' }`,
      ') }',
    ];
    const manifestPath = join(root, 'release', 'mahabbat-release.json');
    const target = join(root, '.private', 'update-target.json');
    const env = { MAHABBAT_DEPLOY_ROOT: root };
    runPs(
      [
        `. '${join(lib, 'mahabbat-common.ps1')}'`,
        `. '${join(lib, 'mahabbat-update-pin.ps1')}'`,
        ...buildPinned(manifestPath),
        `Write-MahabbatUpdateTargetRecord -Path '${target}' -Pinned $pinned | Out-Null`,
        `$r = Test-MahabbatUpdateTargetRecord -Recorded (Get-Content -Raw -LiteralPath '${target}' | ConvertFrom-Json)`,
        'if (-not $r.Ok) { throw ("fresh record must pass: " + $r.Reason) }',
        'Write-Output ROUNDTRIP-FRESH-OK',
      ],
      env,
    );
    // Drift the manifest digest (valid JSON, changed content) → refusal naming the drift.
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    manifest.images.venue.digest = `sha256:${'1'.repeat(64)}`;
    writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), 'utf8');
    const out = runPs(
      [
        `. '${join(lib, 'mahabbat-common.ps1')}'`,
        `. '${join(lib, 'mahabbat-update-pin.ps1')}'`,
        `$r = Test-MahabbatUpdateTargetRecord -Recorded (Get-Content -Raw -LiteralPath '${target}' | ConvertFrom-Json)`,
        'if ($r.Ok) { throw "drifted manifest must refuse" }',
        'Write-Output ("DRIFT-REFUSED: " + $r.Reason)',
      ],
      env,
    );
    assert.match(out, /DRIFT-REFUSED: .*SHA не совпадает/);
  });
});

WIN_ONLY('stale maintenance flag refuses apply before any runtime change', () => {
  withFixtureRoot((root) => {
    writeFileSync(join(root, '.private', 'maintenance.json'), '{"schema":1}\n', 'utf8');
    let out = '';
    let failed = false;
    try {
      out = runPs([`& '${UPDATE_PS1}' -Action apply`], {
        MAHABBAT_DEPLOY_ROOT: root,
        MAHABBAT_BACKUP_ROOT: join(root, 'empty-backups'),
      });
    } catch (e) {
      failed = true;
      out = String((e && e.stdout) || '') + String((e && e.stderr) || '') + String((e && e.message) || '');
    }
    assert.ok(failed, 'stale-window apply must exit non-zero');
    out = out.replace(/\s+/g, ' ');
    assert.match(out, /Незакрытое окно обслуживания/);
    assert.ok(!out.includes('PULL OK'), 'no pull may run on a pre-gate refusal');
    assert.ok(!out.includes('UPDATE OK'), 'no success may print on a pre-gate refusal');
    const journal = readJson(join(root, '.private', 'update-journal.json'));
    const stages = journal.map((e) => `${e.stage}:${e.state}`);
    assert.ok(stages.includes('maintenance:refused'), `journal must record maintenance:refused (${stages.join(', ')})`);
    assert.ok(stages.includes('rollback:skipped'), `rollback must be skipped pre-window (${stages.join(', ')})`);
  });
});

WIN_ONLY('pin lib: repo parsing and file hashing are exact', () => {
  withFixtureRoot((root) => {
    const lib = join(ROOT, 'scripts', 'lib');
    const probe = join(root, 'probe.txt');
    writeFileSync(probe, 'mahabbat-pin-probe', 'utf8');
    const out = runPs(
      [
        `. '${join(lib, 'mahabbat-common.ps1')}'`,
        `. '${join(lib, 'mahabbat-backup-crypto.ps1')}'`,
        `. '${join(lib, 'mahabbat-update-pin.ps1')}'`,
        `if ((Get-MahabbatImageRepoWithoutTag 'ghcr.io/o/mahabbat-twenty:v2.29.0-venue') -ne 'ghcr.io/o/mahabbat-twenty') { throw 'tag strip failed' }`,
        `if ((Get-MahabbatImageRepoWithoutTag 'ghcr.io/o/mahabbat-pos-gateway@sha256:${'2'.repeat(64)}') -ne 'ghcr.io/o/mahabbat-pos-gateway') { throw 'digest strip failed' }`,
        `if ((Get-MahabbatUpdateFileSha256 -Path '${probe}') -ne '${sha256file(probe)}') { throw 'file sha mismatch' }`,
        'Write-Output PINLIB-HELPERS-OK',
      ],
      { MAHABBAT_DEPLOY_ROOT: root },
    );
    assert.match(out, /PINLIB-HELPERS-OK/);
  });
});
