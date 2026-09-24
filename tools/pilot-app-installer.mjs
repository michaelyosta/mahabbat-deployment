import fs from 'node:fs/promises';
import path from 'node:path';
import { appDeploy, appInstall, authLogin } from 'twenty-sdk/cli';

const root = process.env.MAHABBAT_PILOT_ROOT;
if (!root) throw new Error('PILOT_ROOT_MISSING');

const parseEnv = (text) => Object.fromEntries(
  text.split(/\r?\n/)
    .map((line) => line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/))
    .filter(Boolean)
    .map((match) => [match[1], match[2]]),
);

const config = parseEnv(await fs.readFile(path.join(root, '.env'), 'utf8'));
const baseUrl = config.SERVER_URL?.replace(/\/$/, '');
const apiKey = config.MAHABBAT_API_KEY || config.TWENTY_API_KEY;
if (!baseUrl || !apiKey) throw new Error('LOCAL_API_CREDENTIALS_MISSING');

const statusUrl = `http://127.0.0.1:${config.LICENSE_STATUS_PORT || '3199'}/status`;
const licenseResponse = await fetch(statusUrl, { signal: AbortSignal.timeout(5000) });
if (!licenseResponse.ok || !(await licenseResponse.json()).active) {
  throw new Error('ACTIVE_PILOT_LICENSE_REQUIRED');
}

const remote = 'mahabbat-pilot-local';
const login = await authLogin({ apiKey, apiUrl: baseUrl, remote });
if (!login.success) throw new Error('LOCAL_ADMIN_API_KEY_REJECTED');

const appPath = path.join(root, 'app', 'unpacked');
const tarballPath = path.join(root, 'app', 'mahabbat-0.9.0.tgz');
const appManifest = JSON.parse(await fs.readFile(path.join(appPath, 'manifest.json'), 'utf8'));
const appUniversalIdentifier = appManifest.application?.universalIdentifier;
if (!appUniversalIdentifier) throw new Error('MAHABBAT_APP_MANIFEST_INVALID');

const deployment = await appDeploy({
  tarballPath,
  remote,
  onProgress: (message) => console.log(message),
});
if (!deployment.success && deployment.error?.code !== 'VERSION_ALREADY_EXISTS') {
  throw new Error(`MAHABBAT_APP_DEPLOY_FAILED:${deployment.error?.code ?? 'UNKNOWN'}`);
}

const installation = await appInstall({ appPath, remote });
if (!installation.success && installation.error?.code !== 'APP_ALREADY_INSTALLED') {
  throw new Error(`MAHABBAT_APP_INSTALL_FAILED:${installation.error?.code ?? 'UNKNOWN'}`);
}

const requiredObjects = ['posStaffs', 'inventoryStockLocations', 'posPrinterDevices'];
for (const objectName of requiredObjects) {
  const response = await fetch(`${baseUrl}/rest/${objectName}?limit=1`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`MAHABBAT_OBJECT_NOT_READY:${objectName}:${response.status}`);
  await response.body?.cancel();
}

console.log(`MAHABBAT_APP_INSTALL=PASS (${appUniversalIdentifier})`);
