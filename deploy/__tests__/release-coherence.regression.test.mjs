// Gauntlet-TAGFIX regression: publish-once tags (scheme v2, closes R02).
// Release finalized on CRM abd67ec1f0b235eeae9bd51680d650f7c262c2f5
// (origin/main, Stage B tsc green): crmNext consumed, stage-b 97a3cf0 absorbed
// into crmMerged, enforced tags are publish-once v2 names
// sha-<crm12>-<dep12>-<artifact> (dep12 binds the deployment HEAD, so two
// deployment commits never share a name and CI can never push over a tag),
// new-tag digests TBD-after-publish with the digest-fixup v2 procedure
// (rename-then-resolve), v1 two-segment names retired-frozen,
// hostScriptsHash re-hashed byte-for-byte.
// No docker, no registry, no live install: pure file checks.
// Strength rule: exact equalities, anchored regexes over definitions and
// structural lines, explicit allowlists/denylists. No bare `includes` probes:
// a passing check must prove shape + wiring, not mere mention.
//   F09 CI/lock drift .... inner lock commit, upstream digest/ref, manifest
//                           crmSha/upstream all agree by exact equality, and the
//                           enforced identity is EXACTLY the abd67ec release SHA
//   F10 tag binding ..... enforced tags are EXACTLY sha-<crm12>-<dep12>-<artifact>
//                           in both lock and manifest, lock==manifest, and the dep
//                           segment equals the manifest deploymentSha prefix
//                           (the tag binds the deployment HEAD it was minted for)
//   F10-final ........... crmNext consumed, every v1 two-segment name is gone
//                           from the enforced set (retired, never reused), the
//                           08dd2de base is gone, enforced tags are the exact
//                           v2 set, schema patterns enforce v2 and ban v1
//   V1-BANNED ........... the validator (schema pattern + CI assert) rejects
//                           two-segment names: retired names fail the enforced
//                           pattern, enforced names fail the v1 pattern
//   F11 mutable alias ..... updater resolves via lock refs, pins check->apply into
//                           a TargetFile record, gates apply on lock coherence,
//                           and treats the TBD digest sentinel as a supported state
//   F14 version identity .. manifest carries a real Mahabbat version distinct from
//                           1.0.0; CI stamps exact Mahabbat label lines incl. the
//                           deployment label, publishes dep-bound tags through a
//                           no-overwrite gate, and fixup commits do not retrigger
//                           publish; the installer ships the manifest +
//                           SmartScreen note via Source entries
//   PENDING accounting ... stage-b 97a3cf0 lives EXACTLY ONCE in crmMerged with
//                           status merged and mergedInto == enforced crmSha —
//                           pending is empty, nothing vanished silently
//   DIGEST-FIXUP-v2 ...... while any enforced digest is the TBD sentinel, the
//                           manifest carries the exact rename-then-resolve fill
//                           procedure for the dep-bound names
//   RETIRED .............. the v1 names live ONLY in retiredImmutableTags with
//                           status retired-frozen and their last digests —
//                           frozen in GHCR, never republished or reused
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
const CRM_SHA = 'abd67ec1f0b235eeae9bd51680d650f7c262c2f5';
const CRM_SHORT12 = 'abd67ec1f0b2';
const DEP_SHA = '662ddb46b1496b83c9b671b15a59890dfdfaa75b';
const DEP_SHORT12 = '662ddb46b149';
const RETIRED_BASE = '08dd2de9e097';
const TAG_V2_RE = /^sha-([0-9a-f]{12})-([0-9a-f]{12})-(branding|venue|pos-gateway)$/;
const OLD_TAG_RE = /^sha-[0-9a-f]{12}-(branding|venue|pos-gateway)$/;
const RETIRED_V1 = [
  'sha-abd67ec1f0b2-branding',
  'sha-abd67ec1f0b2-venue',
  'sha-abd67ec1f0b2-pos-gateway',
];
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

test('FINAL identity: enforced CRM identity is exactly the abd67ec release SHA', () => {
  const inner = json('mahabbat-inner.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.equal(inner.commit, CRM_SHA, 'inner lock must be pinned to the tsc-green abd67ec release SHA');
  assert.equal(release.crmSha, CRM_SHA, 'manifest crmSha must be exactly the abd67ec release SHA');
  assert.equal(inner.commit.slice(0, 12), CRM_SHORT12, 'lock short prefix must be abd67ec1f0b2');
  assert.match(CRM_SHORT12, SHORT12_RE);
});

test('F09b: deploymentSha is a real short/full SHA, stale values are gone', () => {
  const release = json('release/mahabbat-release.json');
  assert.match(release.deploymentSha, /^[0-9a-f]{7,40}$/, 'deploymentSha must be a hex SHA prefix');
  for (const stale of ['STAGE-D-TBD', '95cb468', '05cdd57', '80cbf492e1d3689acf6c638d1b90d6b39e151854']) {
    assert.notEqual(release.deploymentSha, stale, `stale deploymentSha ${stale} must be synced to fact`);
  }
});

test('F10: enforced tags are exactly sha-<crm12>-<dep12>-<artifact>, bound to the deployment HEAD', () => {
  const inner = json('mahabbat-inner.lock.json');
  const digests = json('image-digests.lock.json');
  const release = json('release/mahabbat-release.json');
  const short = inner.commit.slice(0, 12);
  assert.match(short, SHORT12_RE);
  assert.equal(release.deploymentSha, DEP_SHA, 'blessed tags are minted for the recorded deployment HEAD');
  const depOfRecord = release.deploymentSha.slice(0, 12);
  assert.equal(depOfRecord, DEP_SHORT12, 'deployment prefix must be the blessed dep12');
  const seen = new Set();
  for (const [key, suffix] of ARTIFACTS) {
    const want = `sha-${short}-${depOfRecord}-${suffix}`;
    assert.equal(digests.images[key].immutableTag, want, `lock images.${key} must be exactly ${want}`);
    assert.equal(release.images[key].immutableTag, want, `manifest images.${key} must be exactly ${want}`);
    const m = release.images[key].immutableTag.match(TAG_V2_RE);
    assert.ok(m, `enforced tag must match publish-once v2 shape: ${want}`);
    assert.equal(m[1], short, 'crm segment must be the inner lock short');
    assert.equal(m[2], depOfRecord, 'dep segment must bind the deployment HEAD of record');
    assert.equal(m[3], suffix, 'artifact segment must name the artifact');
    seen.add(want);
  }
  assert.equal(seen.size, ARTIFACTS.length, 'enforced immutable tags collide');
});

test('F10-final: crmNext consumed, v1 two-segment names retired, enforced tags are the exact v2 set', () => {
  const digests = json('image-digests.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.equal(release.crmNext, undefined, 'crmNext must be consumed once the bump is enforced');
  const enforced = ARTIFACTS.map(([k]) => release.images[k].immutableTag);
  const lockTags = ARTIFACTS.map(([k]) => digests.images[k].immutableTag);
  for (const t of [...enforced, ...lockTags]) {
    assert.ok(!t.startsWith(`sha-${RETIRED_BASE}-`), `retired 08dd2de tag name reused: ${t}`);
    assert.ok(!OLD_TAG_RE.test(t), `retired v1 two-segment name reused as enforced tag: ${t}`);
  }
  const next = new Set();
  for (const [key, suffix] of ARTIFACTS) {
    const want = `sha-${CRM_SHORT12}-${DEP_SHORT12}-${suffix}`;
    assert.equal(release.images[key].immutableTag, want, `manifest images.${key} must be exactly ${want}`);
    assert.equal(digests.images[key].immutableTag, want, `lock images.${key} must be exactly ${want}`);
    next.add(want);
  }
  assert.equal(next.size, ARTIFACTS.length, 'enforced immutable tags collide');
  const scheme = digests.tagScheme;
  assert.ok(scheme && scheme.version === 2, 'lock must carry the v2 tagScheme provenance');
  assert.equal(scheme.format, 'sha-<crm12>-<dep12>-<artifact>', 'lock tagScheme format');
  assert.equal(scheme.crm12, CRM_SHORT12, 'lock tagScheme crm12');
  assert.equal(scheme.dep12, DEP_SHORT12, 'lock tagScheme dep12');
  assert.deepEqual([...scheme.retired].sort(), [...RETIRED_V1].sort(), 'lock tagScheme must list the retired v1 names');
  const schema = json('release/mahabbat-release.schema.json');
  assert.ok(schema.properties !== undefined && schema.properties.crmNext !== undefined, 'schema keeps crmNext for future prepared bumps');
  assert.ok(schema.properties.digestFixup !== undefined, 'schema must define digestFixup');
  assert.ok(schema.properties.retiredImmutableTags !== undefined, 'schema must define retiredImmutableTags');
  const enforcedPattern = schema.definitions.artifact.properties.immutableTag.pattern;
  assert.equal(
    enforcedPattern,
    '^sha-[0-9a-f]{12}-[0-9a-f]{12}-(branding|venue|pos-gateway)$',
    'schema enforced pattern must require the dep segment (v2)',
  );
  const nextPattern = schema.definitions.nextArtifact.properties.immutableTag.pattern;
  assert.equal(
    nextPattern,
    '^sha-[0-9a-f]{12}-[0-9a-f]{12}-(branding|venue|pos-gateway)$',
    'schema crmNext pattern must require the dep segment (v2)',
  );
});

test('V1-BANNED: two-segment names fail the validator, v2 names fail the v1 shape', () => {
  const schema = json('release/mahabbat-release.schema.json');
  const enforcedRe = new RegExp(schema.definitions.artifact.properties.immutableTag.pattern);
  const release = json('release/mahabbat-release.json');
  for (const t of RETIRED_V1) {
    assert.ok(!enforcedRe.test(t), `validator must reject retired v1 name: ${t}`);
  }
  for (const [key] of ARTIFACTS) {
    const t = release.images[key].immutableTag;
    assert.ok(enforcedRe.test(t), `enforced tag must pass the schema validator: ${t}`);
    assert.ok(!OLD_TAG_RE.test(t), `enforced tag must not match the retired v1 shape: ${t}`);
  }
  const ci = read('.github/workflows/publish-images.yml');
  assert.match(
    ci,
    /is not publish-once v2 \(sha-<crm12>-<dep12>-<artifact>\); v1 two-segment names are retired and banned/,
    'CI validator must ban v1 two-segment names with an explicit failure',
  );
});

test('PENDING accounting: stage-b 97a3cf0 merged exactly once, pending is empty', () => {
  const release = json('release/mahabbat-release.json');
  const pending = Array.isArray(release.crmPending) ? release.crmPending : [];
  const merged = Array.isArray(release.crmMerged) ? release.crmMerged : [];
  assert.equal(pending.length, 0, 'no open pending entries may remain after the abd67ec flip');
  assert.equal(merged.length, 1, 'crmMerged must carry exactly the absorbed stage-b entry');
  const e = merged[0];
  assert.equal(e.sha, STAGE_B_SHA, 'merged entry must be stage-b 97a3cf0');
  assert.equal(e.status, 'merged', 'crmMerged entries must carry status merged');
  assert.equal(e.mergedInto, CRM_SHA, 'absorbed commit must be the enforced abd67ec crmSha');
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

test('DIGEST-FIXUP-v2: TBD digests carry the rename-then-resolve fill procedure', () => {
  const release = json('release/mahabbat-release.json');
  const tbdKeys = ARTIFACTS.filter(([key]) => release.images[key].digest === TBD_DIGEST);
  if (tbdKeys.length === 0) return;
  assert.ok(
    Array.isArray(release.digestFixup) && release.digestFixup.length >= 5,
    'while digests are TBD the manifest must carry the digest-fixup v2 procedure',
  );
  for (const step of release.digestFixup) {
    assert.ok(typeof step === 'string' && step.length > 0, 'fixup steps must be non-empty');
  }
  const text = release.digestFixup.join('\n');
  assert.ok(text.includes(CRM_SHORT12), 'fixup must name the enforced crm short SHA');
  assert.ok(text.includes(DEP_SHORT12), 'fixup must name the blessed dep12 (rename-then-resolve needs it)');
  assert.ok(text.includes('RENAME'), 'fixup v2 must recompute names for the publish HEAD before resolving digests');
  assert.ok(text.includes('imagetools'), 'fixup must resolve digests via imagetools (CI record-step mirror)');
  for (const [, suffix] of ARTIFACTS) {
    assert.ok(
      text.includes(`sha-${CRM_SHORT12}-<H12>-${suffix}`),
      `fixup must name the dep-parameterized immutable tag sha-${CRM_SHORT12}-<H12>-${suffix}`,
    );
  }
  for (const t of RETIRED_V1) {
    assert.ok(text.includes(t), `fixup must forbid republishing the retired v1 tag ${t}`);
  }
  assert.ok(text.includes(RETIRED_BASE), 'fixup must forbid republishing the retired 08dd2de tags');
  assert.ok(
    text.includes('does NOT retrigger publish-images.yml'),
    'fixup must commit manifest+lock without retriggering publish (or every fixup mints orphans)',
  );
  assert.ok(
    text.includes('release-coherence.regression.test.mjs'),
    'fixup must end with the coherence test gate',
  );
});

test('RETIRED: v1 names live only in retiredImmutableTags, frozen with last digests', () => {
  const release = json('release/mahabbat-release.json');
  const retired = release.retiredImmutableTags;
  assert.ok(Array.isArray(retired) && retired.length === RETIRED_V1.length, 'retired record must list exactly the v1 set');
  const enforced = new Set(ARTIFACTS.map(([k]) => release.images[k].immutableTag));
  const seenTags = new Set();
  for (const entry of retired) {
    assert.ok(RETIRED_V1.includes(entry.tag), `unexpected retired entry: ${entry.tag}`);
    assert.match(entry.digest, REAL_DIGEST_RE, `${entry.tag}: retired digest must stay a real recorded digest`);
    assert.equal(entry.status, 'retired-frozen', `${entry.tag}: retired status must be retired-frozen`);
    assert.ok(typeof entry.note === 'string' && entry.note.length > 0, `${entry.tag}: retired entry needs a note`);
    assert.ok(!enforced.has(entry.tag), `retired tag must never equal an enforced tag: ${entry.tag}`);
    assert.ok(OLD_TAG_RE.test(entry.tag), `retired entry must be a v1 two-segment name: ${entry.tag}`);
    seenTags.add(entry.tag);
  }
  assert.deepEqual([...seenTags].sort(), [...RETIRED_V1].sort(), 'retired set must be exactly the v1 names');
  const schema = json('release/mahabbat-release.schema.json');
  const retiredRe = new RegExp(schema.properties.retiredImmutableTags.items.properties.tag.pattern);
  for (const t of RETIRED_V1) {
    assert.ok(retiredRe.test(t), `schema retired pattern must accept the v1 name: ${t}`);
  }
  const enforcedRe = new RegExp(schema.definitions.artifact.properties.immutableTag.pattern);
  for (const t of RETIRED_V1) {
    assert.ok(!enforcedRe.test(t), `schema enforced pattern must reject the retired name: ${t}`);
  }
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
  const depLabels = [...ci.matchAll(/^\s+io\.mahabbat\.deployment\s*=\s*\$\{\{\s*steps\.dep\.outputs\.dep\s*\}\}\s*$/gm)];
  assert.equal(depLabels.length, 3, 'CI must stamp the deployment HEAD label on all three images (tag<->tree binding)');
  const constructed = [...ci.matchAll(/tag_\w+=sha-\$\{crm_short\}-\$\{dep_short\}-(branding|venue|pos-gateway)/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(constructed)].sort(), ['branding', 'pos-gateway', 'venue'], 'CI must construct dep-bound sha-<crm12>-<dep12>-<artifact> names for all three artifacts');
  const wired = [...ci.matchAll(/\$\{\{\s*steps\.dep\.outputs\.tag_(branding|venue|pos_gateway)\s*\}\}/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(wired)].sort(), ['branding', 'pos_gateway', 'venue'], 'CI builds must push the dep-bound computed tags');
  const noOverwriteGuards = ci.match(/outputs\.exists != 'true'/g) || [];
  assert.equal(noOverwriteGuards.length, 3, 'CI must gate all three builds on the inspect-before-push result (never push over an existing tag)');
  assert.match(ci, /docker buildx imagetools inspect/, 'CI must inspect the tag before pushing (exists => reuse digest, no rebuild)');
  assert.match(ci, /already published; build skipped, digest reused/, 'CI must reuse the digest without rebuild when the tag exists');
  const pathsBlock = ci.match(/paths:\s*\n((?:\s+- '[^']+'\s*\n)+)/);
  assert.ok(pathsBlock, 'CI push trigger must declare a paths allowlist');
  assert.ok(!pathsBlock[1].includes('release/'), 'manifest/schema fixup commits must not retrigger publish (or every fixup mints an orphan tag set)');
  assert.ok(!pathsBlock[1].includes('image-digests.lock.json'), 'fixup RENAME writes image-digests.lock.json: it must not retrigger publish (same orphan loop via the lock trigger)');
  const iss = read('installer/build/mahabbat-setup.iss');
  assert.match(iss, /^Source:\s*"[^"]*release\\mahabbat-release\.json";\s*DestDir:/m, 'installer must ship the release manifest');
  assert.match(iss, /^Source:\s*"[^"]*UNLICENSED-SMARTSCREEN-NOTE\.md";\s*DestDir:/m, 'installer must ship the SmartScreen note');
  assert.ok(!/C:\\Users\\misa|hermes\\\\node/.test(iss), 'installer must not hardcode a personal Node path');
  const schema = json('release/mahabbat-release.schema.json');
  assert.ok(Array.isArray(schema.required) && schema.required.includes('mahabbatVersion'), 'schema guards the version');
});
