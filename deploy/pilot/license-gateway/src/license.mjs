import { createHash, createPublicKey, verify } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

const MAX_JSON_BYTES = 1024 * 1024;
const REQUIRED_FEATURES = ['crm', 'pos', 'inventory', 'printing'];

export const canonicalJson = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    const entries = Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`);
    return `{${entries.join(',')}}`;
  }
  const encoded = JSON.stringify(value);
  if (encoded === undefined) throw new TypeError('Unsupported value in signed payload');
  return encoded;
};

const readJson = async (filePath) => {
  const bytes = await readFile(filePath);
  if (bytes.byteLength > MAX_JSON_BYTES) throw new Error('JSON file exceeds limit');
  return JSON.parse(bytes.toString('utf8'));
};

const writeJsonAtomically = async (filePath, value) => {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value)}\n`, { flag: 'wx', mode: 0o600 });
  await rename(temporary, filePath);
};

const fail = (status, reason) => ({ status, reason, active: false });

const validFingerprint = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const validId = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

const verifyPayload = (document, publicKey) => {
  if (!document || typeof document !== 'object' || Array.isArray(document)) return false;
  const { payload, signature } = document;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload) || typeof signature !== 'string') return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(signature)) return false;
  try {
    return verify(null, Buffer.from(canonicalJson(payload), 'utf8'), createPublicKey(publicKey), Buffer.from(signature, 'base64'));
  } catch {
    return false;
  }
};

export async function evaluateLicense({
  licensePath,
  installationPath,
  publicKeyPath,
  statePath,
  now = Date.now(),
  clockToleranceMs = 5 * 60 * 1000,
}) {
  let installation;
  try {
    installation = await readJson(installationPath);
  } catch {
    return fail('INSTALLATION_CONFIG_MISSING', 'INSTALLATION_CONFIG_MISSING');
  }
  if (!validId(installation.installation_id) || !validFingerprint(installation.machine_fingerprint)) {
    return fail('INSTALLATION_CONFIG_INVALID', 'INSTALLATION_CONFIG_INVALID');
  }

  let previous;
  try {
    previous = await readJson(statePath);
  } catch (error) {
    if (error?.code !== 'ENOENT') return fail('CLOCK_STATE_UNAVAILABLE', 'CLOCK_STATE_UNAVAILABLE');
  }

  if (previous) {
    if (previous.installation_id !== installation.installation_id) {
      return fail('CLOCK_STATE_MISMATCH', 'CLOCK_STATE_MISMATCH');
    }
    const lastSeen = Date.parse(previous.last_seen_utc);
    if (!Number.isFinite(lastSeen)) return fail('CLOCK_STATE_INVALID', 'CLOCK_STATE_INVALID');
    if (now + clockToleranceMs < lastSeen) return fail('CLOCK_ROLLBACK', 'CLOCK_ROLLBACK');
  }

  const lastSeen = previous ? Date.parse(previous.last_seen_utc) : 0;
  if (!previous || now > lastSeen) {
    try {
      await writeJsonAtomically(statePath, {
        version: 1,
        installation_id: installation.installation_id,
        last_seen_utc: new Date(now).toISOString(),
      });
    } catch {
      return fail('CLOCK_STATE_UNAVAILABLE', 'CLOCK_STATE_UNAVAILABLE');
    }
  }

  let document;
  let publicKey;
  try {
    [document, publicKey] = await Promise.all([readJson(licensePath), readFile(publicKeyPath, 'utf8')]);
  } catch (error) {
    if (error?.code === 'ENOENT') return fail('NO_LICENSE', 'NO_LICENSE');
    return fail('LICENSE_UNREADABLE', 'LICENSE_UNREADABLE');
  }

  if (!verifyPayload(document, publicKey)) return fail('INVALID_LICENSE_SIGNATURE', 'INVALID_LICENSE_SIGNATURE');
  const payload = document.payload;
  if (
    payload.schema_version !== 1 ||
    payload.product !== 'Mahabbat' ||
    payload.type !== 'pilot' ||
    !validId(payload.installation_id) ||
    !validFingerprint(payload.machine_fingerprint) ||
    typeof payload.customer !== 'string' || payload.customer.trim().length === 0 ||
    !Array.isArray(payload.features) || !REQUIRED_FEATURES.every((feature) => payload.features.includes(feature))
  ) return fail('INVALID_LICENSE_PAYLOAD', 'INVALID_LICENSE_PAYLOAD');

  if (payload.installation_id !== installation.installation_id) return fail('INSTALLATION_MISMATCH', 'INSTALLATION_MISMATCH');
  if (payload.machine_fingerprint !== installation.machine_fingerprint) return fail('MACHINE_MISMATCH', 'MACHINE_MISMATCH');

  const issuedAt = Date.parse(payload.issued_at);
  const expiresAt = Date.parse(payload.expires_at);
  if (!Number.isFinite(issuedAt) || !Number.isFinite(expiresAt) || expiresAt <= issuedAt) {
    return fail('INVALID_LICENSE_DATES', 'INVALID_LICENSE_DATES');
  }
  if (now + clockToleranceMs < issuedAt) return fail('LICENSE_NOT_YET_VALID', 'LICENSE_NOT_YET_VALID');
  if (now >= expiresAt) return fail('LICENSE_EXPIRED', 'LICENSE_EXPIRED');

  return {
    active: true,
    status: 'ACTIVE',
    reason: 'LICENSE_VALID',
    customer: payload.customer,
    type: payload.type,
    issuedAt: new Date(issuedAt).toISOString(),
    expiresAt: new Date(expiresAt).toISOString(),
    features: [...payload.features],
    installationId: installation.installation_id,
    licenseDigest: createHash('sha256').update(canonicalJson(payload)).digest('hex'),
  };
}

export const publicLicenseStatus = (state) => ({
  status: state.status ?? state.reason,
  active: Boolean(state.active),
  customer: state.active ? state.customer : undefined,
  type: state.active ? state.type : undefined,
  expiresAt: state.active ? state.expiresAt : undefined,
  features: state.active ? state.features : undefined,
});
