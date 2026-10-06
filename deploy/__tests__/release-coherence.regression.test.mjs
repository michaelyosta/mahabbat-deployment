// Gauntlet-T3-FINAL regression: release identity coherence (F09/F10/F11/F14).
// Release finalized on CRM 91ffda36de35e8a39f09f48d1eef3581aed2613a
// (origin/main, Stage B tsc green): crmNext consumed, stage-b 97a3cf0 absorbed
// into crmMerged, enforced tags re-derived, new-tag digests TBD-after-publish
// with an exact digest-fixup procedure, hostScriptsHash re-hashed byte-for-byte.
// No docker, no registry, no live install: pure file checks.
// Strength rule: exact equalities, anchored regexes over definitions and
// structural lines, explicit allowlists/denylists. No bare `includes` probes:
// a passing check must prove shape + wiring, not mere mention.
//   F09 CI/lock drift .... inner lock commit, upstream digest/ref, manifest
//                           crmSha/upstream all agree by exact equality, and the
//                           enforced identity is EXACTLY the 91ffda3 release SHA
//   F10 tag collision .... enforced tags are EXACTLY sha-<lockshort12>-<artifact>
//                           in both lock and manifest; the retired 08dd2de base
//                           is gone from every enforced tag name (never reused)
//   F11 mutable alias ..... updater resolves via lock refs, pins check->apply into
//                           a TargetFile record, gates apply on lock coherence,
//                           and treats the TBD digest sentinel as a supported state
//   F14 version identity .. manifest carries a real Mahabbat version distinct from
//                           1.0.0; CI stamps exact Mahabbat label lines; the installer
//                           ships the manifest + SmartScreen note via Source entries
//   PENDING accounting ... stage-b 97a3cf0 lives EXACTLY ONCE in crmMerged with
//                           status merged and mergedInto == enforced crmSha —
//                           pending is empty, nothing vanished silently
//   DIGEST-FIXUP ......... while any enforced digest is the TBD sentinel, the
//                           manifest carries the exact post-publish fill procedure
//   HOSTSCRIPTS .......... every manifest hostScriptsHash entry matches the
//                           merged tree byte-for-byte (sha256 over raw bytes)
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

const ROOT = join(import.meta.dirname, '..', '..');
const read = (rel) => readFileSync(join(ROOT, rel), 'utf8');
const json = (rel) => JSON.parse(read(rel));

const FULL_SHA_RE = /^[0-9a-f]{40}$/;
const SHORT12_RE = /^[0-9a-f]{12}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;
const REAL_DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const TBD_DIGEST = 'sha256:TBD-after-publish';
const STAGE_B_SHA = '97a3cf0f77e92da2c74243bcd2ed7c044740ee29';
const CRM_SHA = '91ffda36de35e8a39f09f48d1eef3581aed2613a';
const CRM_SHORT12 = '91ffda36de35';
const RETIRED_BASE = '08dd2de9e097';
const INNER_REPO = 'https://github.com/michaelyosta/mahabbat-crm.git';
const ARTIFACTS = [
  ['branding', 'branding'],
  ['venue', 'venue'],
  ['posGateway', 'pos-gateway'],
];

test('F09: inner lock, manifest crmSha and upstream pin agree by exact equality', () => {
  const inner = json('mahabbat-inner.lock.json');
  const digests = json('image-digests.lock.json');
  const upstream = json('upstream-twenty.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.match(inner.commit, FULL_SHA_RE, 'inner lock must be a full SHA');
  assert.equal(inner.repository, INNER_REPO, 'inner lock repository drift');
  assert.equal(release.crmSha, inner.commit, 'release manifest crmSha must equal the inner lock');
  assert.equal(
    release.upstreamPin.digest,
    digests.images.twenty.digest,
    'release upstream digest must equal the locked twenty digest',
  );
  assert.match(release.upstreamPin.digest, REAL_DIGEST_RE, 'upstream digest must be a real published digest');
  assert.equal(release.upstreamPin.ref, upstream.ref, 'upstream ref drift');
  assert.match(release.upstreamPin.commit, FULL_SHA_RE, 'upstream pin commit must be a full SHA');
  if (release.crmNext !== undefined) {
    assert.match(release.crmNext.sha, FULL_SHA_RE, 'crmNext.sha must be a full SHA');
    assert.notEqual(inner.commit, release.crmNext.sha, 'prepared bump must NOT be enforced while crmNext is present');
    assert.notEqual(release.crmSha, release.crmNext.sha, 'crmSha flip waits for the green gate');
  }
});

test('FINAL identity: enforced CRM identity is exactly the 91ffda3 release SHA', () => {
  const inner = json('mahabbat-inner.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.equal(inner.commit, CRM_SHA, 'inner lock must be pinned to the tsc-green 91ffda3 release SHA');
  assert.equal(release.crmSha, CRM_SHA, 'manifest crmSha must be exactly the 91ffda3 release SHA');
  assert.equal(inner.commit.slice(0, 12), CRM_SHORT12, 'lock short prefix must be 91ffda36de35');
  assert.match(CRM_SHORT12, SHORT12_RE);
});

test('F09b: deploymentSha is a real short/full SHA, stale values are gone', () => {
  const release = json('release/mahabbat-release.json');
  assert.match(release.deploymentSha, /^[0-9a-f]{7,40}$/, 'deploymentSha must be a hex SHA prefix');
  for (const stale of ['STAGE-D-TBD', '95cb468', '05cdd57']) {
    assert.notEqual(release.deploymentSha, stale, `stale deploymentSha ${stale} must be synced to fact`);
  }
});

test('F10: enforced immutable tags are exactly sha-<lockshort12>-<artifact> in lock and manifest', () => {
  const inner = json('mahabbat-inner.lock.json');
  const digests = json('image-digests.lock.json');
  const release = json('release/mahabbat-release.json');
  const short = inner.commit.slice(0, 12);
  assert.match(short, SHORT12_RE);
  const seen = new Set();
  for (const [key, suffix] of ARTIFACTS) {
    const want = `sha-${short}-${suffix}`;
    assert.equal(digests.images[key].immutableTag, want, `lock images.${key} must be exactly ${want}`);
    assert.equal(release.images[key].immutableTag, want, `manifest images.${key} must be exactly ${want}`);
    seen.add(want);
  }
  assert.equal(seen.size, ARTIFACTS.length, 'enforced immutable tags collide');
});

test('F10-final: crmNext consumed, retired 08dd2de base gone, enforced tags are the 91ffda3 set', () => {
  const digests = json('image-digests.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.equal(release.crmNext, undefined, 'crmNext must be consumed once the bump is enforced');
  const enforced = ARTIFACTS.map(([k]) => release.images[k].immutableTag);
  const lockTags = ARTIFACTS.map(([k]) => digests.images[k].immutableTag);
  for (const t of [...enforced, ...lockTags]) {
    assert.ok(!t.startsWith(`sha-${RETIRED_BASE}-`), `retired tag name reused: ${t}`);
  }
  const next = new Set();
  for (const [key, suffix] of ARTIFACTS) {
    const want = `sha-${CRM_SHORT12}-${suffix}`;
    assert.equal(release.images[key].immutableTag, want, `manifest images.${key} must be exactly ${want}`);
    assert.equal(digests.images[key].immutableTag, want, `lock images.${key} must be exactly ${want}`);
    next.add(want);
  }
  assert.equal(next.size, ARTIFACTS.length, 'enforced immutable tags collide');
  const schema = json('release/mahabbat-release.schema.json');
  assert.ok(schema.properties !== undefined && schema.properties.crmNext !== undefined, 'schema keeps crmNext for future prepared bumps');
  assert.ok(schema.properties.digestFixup !== undefined, 'schema must define digestFixup');
});

test('PENDING accounting: stage-b 97a3cf0 merged exactly once, pending is empty', () => {
  const release = json('release/mahabbat-release.json');
  const pending = Array.isArray(release.crmPending) ? release.crmPending : [];
  const merged = Array.isArray(release.crmMerged) ? release.crmMerged : [];
  assert.equal(pending.length, 0, 'no open pending entries may remain after the 91ffda3 flip');
  assert.equal(merged.length, 1, 'crmMerged must carry exactly the absorbed stage-b entry');
  const e = merged[0];
  assert.equal(e.sha, STAGE_B_SHA, 'merged entry must be stage-b 97a3cf0');
  assert.equal(e.status, 'merged', 'crmMerged entries must carry status merged');
  assert.equal(e.mergedInto, CRM_SHA, 'absorbed commit must be the enforced 91ffda3 crmSha');
  assert.equal(e.mergedInto, release.crmSha, 'absorbed commit must equal the enforced crmSha');
  assert.ok(typeof e.branch === 'string' && e.branch.length > 0, 'merged entry needs a branch');
  assert.ok(typeof e.reason === 'string' && e.reason.length > 0, 'merged entry needs a reason');
  const hits =
    pending.filter((x) => x.sha === STAGE_B_SHA).length + merged.filter((x) => x.sha === STAGE_B_SHA).length;
  assert.equal(hits, 1, `stage-b ${STAGE_B_SHA} must be accounted exactly once (pending XOR merged), found ${hits}`);
});

test('DIGESTS allowlist: enforced digests are real or the explicit TBD sentinel', () => {
  const release = json('release/mahabbat-release.json');
  for (const [key] of ARTIFACTS) {
    const d = release.images[key].digest;
    assert.ok(d === TBD_DIGEST || REAL_DIGEST_RE.test(d), `images.${key}.digest is neither published nor TBD: ${d}`);
  }
  assert.match(release.upstreamPin.digest, REAL_DIGEST_RE, 'upstream digest must always be real');
});

test('DIGEST-FIXUP: TBD digests carry the exact post-publish fill procedure', () => {
  const release = json('release/mahabbat-release.json');
  const tbdKeys = ARTIFACTS.filter(([key]) => release.images[key].digest === TBD_DIGEST);
  if (tbdKeys.length === 0) return;
  assert.ok(
    Array.isArray(release.digestFixup) && release.digestFixup.length >= 4,
    'while digests are TBD the manifest must carry the digest-fixup procedure',
  );
  for (const step of release.digestFixup) {
    assert.ok(typeof step === 'string' && step.length > 0, 'fixup steps must be non-empty');
  }
  const text = release.digestFixup.join('\n');
  assert.ok(text.includes(CRM_SHORT12), 'fixup must name the enforced short SHA');
  assert.ok(text.includes('imagetools'), 'fixup must resolve digests via imagetools (CI record-step mirror)');
  for (const [, suffix] of ARTIFACTS) {
    assert.ok(
      text.includes(`sha-${CRM_SHORT12}-${suffix}`),
      `fixup must name the exact immutable tag sha-${CRM_SHORT12}-${suffix}`,
    );
  }
  assert.ok(text.includes(RETIRED_BASE), 'fixup must forbid republishing the retired 08dd2de tags');
  assert.ok(
    text.includes('release-coherence.regression.test.mjs'),
    'fixup must end with the coherence test gate',
  );
});

test('HOSTSCRIPTS: manifest hashes match the merged tree byte-for-byte', () => {
  const release = json('release/mahabbat-release.json');
  assert.equal(release.hostScriptsHash.algorithm, 'sha256', 'hash algorithm must be sha256');
  const entries = Object.entries(release.hostScriptsHash.files);
  assert.ok(entries.length > 0, 'hostScriptsHash must list files');
  for (const [rel, hex] of entries) {
    assert.match(hex, HEX64_RE, `${rel}: recorded hash must be 64 hex chars`);
    const raw = readFileSync(join(ROOT, rel));
    const actual = createHash('sha256').update(raw).digest('hex');
    assert.equal(actual, hex, `${rel}: on-disk bytes do not match the recorded hash`);
  }
});

test('F11: updater defines lock/pin functions, pins the check record, gates apply, supports TBD', () => {
  const lib = read('scripts/lib/mahabbat-common.ps1');
  const update = read('scripts/mahabbat-update.ps1');
  const pinlib = read('scripts/lib/mahabbat-update-pin.ps1');
  assert.match(lib, /^function\s+Get-MahabbatImageDigestsLock\b/m, 'common lib must define Get-MahabbatImageDigestsLock');
  assert.match(lib, /^function\s+Get-MahabbatLock\b/m, 'common lib must define Get-MahabbatLock');
  assert.match(lib, /^function\s+Assert-MahabbatImageDigests\b/m, 'common lib must define Assert-MahabbatImageDigests');
  assert.match(update, /\$updateLock\s*=\s*Get-MahabbatImageDigestsLock/, 'updater must resolve targets through the digests lock');
  assert.match(update, /^function\s+Get-MahabbatUpdatePinnedTarget\b/m, 'updater must define Get-MahabbatUpdatePinnedTarget');
  assert.match(
    pinlib,
    /deploymentSha\s*=\s*\[string\]\$release\.deploymentSha/,
    'check record must pin the deployment SHA',
  );
  assert.match(pinlib, /crmSha\s*=\s*\[string\]\$release\.crmSha/, 'check record must pin the CRM SHA');
  assert.match(pinlib, /ConvertTo-Json/, 'check record must be serialized to the TargetFile');
  assert.match(
    update,
    /release crmSha != mahabbat-inner\.lock\.json commit/,
    'apply must refuse when manifest crmSha drifts from the inner lock',
  );
  assert.match(
    update,
    /\$lock\.images\.\(\$pair\[0\]\)/,
    'apply must compare lock vs manifest immutable tags per artifact',
  );
  assert.match(update, /entry\.immutableTag\s+-ne/, 'tag mismatch must fail the apply gate');
  assert.match(update, /\$pinned\s+-match\s+'TBD'/, 'updater must treat the TBD digest sentinel as a supported state');
  const compose = read('docker-compose.yml');
  assert.match(
    compose,
    /\$\{MAHABBAT_TWENTY_IMAGE:-\S*mahabbat-twenty:\S+/,
    'compose must resolve the venue image through the MAHABBAT_TWENTY_IMAGE interpolation',
  );
  assert.match(
    compose,
    /\$\{MAHABBAT_POS_IMAGE:-\S*mahabbat-pos-gateway:\S+/,
    'compose must resolve the POS image through the MAHABBAT_POS_IMAGE interpolation',
  );
  assert.match(compose, /^[^#\n]*MAHABBAT_PULL_POLICY/m, 'compose keeps the pull gate on a live line');
});

test('F14: release carries a real Mahabbat version with exact Mahabbat label lines and installer Source entries', () => {
  const release = json('release/mahabbat-release.json');
  assert.match(release.mahabbatVersion, /^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$/, 'Mahabbat version shape');
  assert.notEqual(release.mahabbatVersion, '1.0.0', 'candidate must be distinguishable from the installed 1.0.0');
  assert.match(release.windowsFileVersion, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/, 'numeric Windows file version');
  const ci = read('.github/workflows/publish-images.yml');
  assert.match(
    ci,
    /^\s+org\.opencontainers\.image\.revision\s*=\s*\$\{\{\s*steps\.lock\.outputs\.sha\s*\}\}\s*$/m,
    'CI must stamp the OCI revision label from the locked SHA',
  );
  assert.match(
    ci,
    /^\s+io\.mahabbat\.release\s*=\s*1\.1\.0-rc\.1\s*$/m,
    'CI must stamp the exact Mahabbat release label line',
  );
  const artifacts = [...ci.matchAll(/^\s+io\.mahabbat\.artifact\s*=\s*(\S+)\s*$/gm)].map((m) => m[1]);
  assert.deepEqual([...new Set(artifacts)].sort(), ['branding', 'pos-gateway', 'venue'], 'CI must label all three artifacts');
  const tagLines = [...ci.matchAll(/sha-\$\{\{\s*steps\.lock\.outputs\.short\s*\}\}-(\S+)/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(tagLines)].sort(), ['branding', 'pos-gateway', 'venue'], 'CI must publish distinct sha-<short>-<artifact> tags');
  const iss = read('installer/build/mahabbat-setup.iss');
  assert.match(iss, /^Source:\s*"[^"]*release\\mahabbat-release\.json";\s*DestDir:/m, 'installer must ship the release manifest');
  assert.match(iss, /^Source:\s*"[^"]*UNLICENSED-SMARTSCREEN-NOTE\.md";\s*DestDir:/m, 'installer must ship the SmartScreen note');
  assert.ok(!/C:\\Users\\misa|hermes\\\\node/.test(iss), 'installer must not hardcode a personal Node path');
  const schema = json('release/mahabbat-release.schema.json');
  assert.ok(Array.isArray(schema.required) && schema.required.includes('mahabbatVersion'), 'schema guards the version');
});
