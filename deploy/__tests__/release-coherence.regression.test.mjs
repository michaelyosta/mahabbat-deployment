// Stage D regression: release identity coherence (F09/F10/F11/F14).
// No docker, no registry, no live install: pure file checks.
//   F09 CI/lock drift .... lock inner SHA, upstream digest, manifest crmSha/upstream all agree
//   F10 tag collision .... branding vs venue vs posGateway immutable tags are distinct
//   F11 mutable alias ..... updater + compose resolve via digest-pinned or lock refs, never bare mutable drift
//   F14 version identity .. manifest carries a real Mahabbat version distinct from 1.0.0; CI stamps Mahabbat labels
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

const ROOT = join(import.meta.dirname, '..', '..');
const read = (rel) => readFileSync(join(ROOT, rel), 'utf8');
const json = (rel) => JSON.parse(read(rel));

const INNER_SHA_RE = /^[0-9a-f]{40}$/;
const KNOWN_INNER = '08dd2de9e097d0f807522c30f020bb666eb7d6b0';

test('F09: lock/manifest/upstream agree on one inner SHA and one upstream digest', () => {
  const inner = json('mahabbat-inner.lock.json');
  const digests = json('image-digests.lock.json');
  const release = json('release/mahabbat-release.json');
  assert.match(inner.commit, INNER_SHA_RE, 'inner lock must be a full SHA');
  assert.equal(inner.commit, KNOWN_INNER, 'inner lock pins the agreed CRM base');
  assert.equal(release.crmSha, inner.commit, 'release manifest crmSha must equal the inner lock');
  assert.equal(
    release.upstreamPin.digest,
    digests.images.twenty.digest,
    'release upstream digest must equal the locked twenty digest',
  );
  assert.equal(release.upstreamPin.ref, json('upstream-twenty.lock.json').ref, 'upstream ref drift');
});

test('F10: branding/venue/posGateway immutable tags are pairwise distinct', () => {
  const digests = json('image-digests.lock.json');
  const tags = [
    digests.images.branding.immutableTag,
    digests.images.venue.immutableTag,
    digests.images.posGateway.immutableTag,
  ];
  for (const t of tags) assert.match(String(t), /^sha-[0-9a-f]{12}-/, 'immutable tag shape');
  assert.equal(new Set(tags).size, 3, `immutable tags collide: ${tags.join(', ')}`);
  const release = json('release/mahabbat-release.json');
  const rtags = [release.images.branding.immutableTag, release.images.venue.immutableTag, release.images.posGateway.immutableTag];
  assert.equal(new Set(rtags).size, 3, 'release manifest tags collide');
  const ci = read('.github/workflows/publish-images.yml');
  assert.ok(ci.includes('-branding'), 'CI must publish a distinct branding tag');
  assert.ok(ci.includes('-venue'), 'CI must publish a distinct venue tag');
  assert.ok(ci.includes('-pos-gateway'), 'CI must publish a distinct POS tag');
});

test('F11: updater resolves pinned refs; check output pins the applied target', () => {
  const update = read('scripts/mahabbat-update.ps1');
  assert.ok(update.includes('Get-MahabbatImageDigestsLock'), 'updater must consult the digests lock');
  assert.ok(update.includes('PinnedTarget') || update.includes('pinnedTarget') || update.includes('TargetDigest'), 'apply must pin the checked digest');
  const compose = read('docker-compose.yml');
  assert.ok(compose.includes('MAHABBAT_PULL_POLICY'), 'compose keeps the pull gate');
});

test('F14: release carries a real Mahabbat version with Mahabbat labels/provenance', () => {
  const release = json('release/mahabbat-release.json');
  assert.match(release.mahabbatVersion, /^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$/, 'Mahabbat version shape');
  assert.notEqual(release.mahabbatVersion, '1.0.0', 'candidate must be distinguishable from the installed 1.0.0');
  assert.match(release.windowsFileVersion, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/, 'numeric Windows file version');
  const ci = read('.github/workflows/publish-images.yml');
  assert.ok(ci.includes('io.mahabbat.release'), 'CI must stamp Mahabbat release labels');
  assert.ok(ci.includes('org.opencontainers.image.revision'), 'CI must stamp OCI revision');
  assert.ok(!ci.includes('org.opencontainers.image.description') || ci.includes('Mahabbat'), 'no inherited Twenty description as Mahabbat changelog');
  const schema = json('release/mahabbat-release.schema.json');
  assert.ok(Array.isArray(schema.required) && schema.required.includes('mahabbatVersion'), 'schema guards the version');
});
