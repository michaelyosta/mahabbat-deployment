#!/usr/bin/env node
import { createPrivateKey, generateKeyPairSync, sign } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { canonicalJson } from '../../deploy/pilot/license-gateway/src/license.mjs';

const usage = () => {
  console.error('Usage:\n  node license-cli.mjs init --private-key <path> --public-key <path>\n  node license-cli.mjs issue --private-key <path> --activation-request <path> --customer <name> --days <1..365> --output <path>');
  process.exitCode = 2;
};

const argumentsMap = (items) => {
  const result = new Map();
  for (let i = 0; i < items.length; i += 2) {
    if (!items[i]?.startsWith('--') || !items[i + 1]) throw new Error('Invalid command arguments');
    result.set(items[i].slice(2), items[i + 1]);
  }
  return result;
};

const writeNew = async (filePath, value, mode) => {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, value, { flag: 'wx', mode });
};

const main = async () => {
  const [command, ...args] = process.argv.slice(2);
  if (!['init', 'issue'].includes(command)) return usage();
  const options = argumentsMap(args);

  if (command === 'init') {
    const privatePath = path.resolve(options.get('private-key') ?? '');
    const publicPath = path.resolve(options.get('public-key') ?? '');
    if (privatePath === path.resolve('.') || publicPath === path.resolve('.') || privatePath === publicPath) throw new Error('Both key file paths are required and must differ');
    const pair = generateKeyPairSync('ed25519');
    const privatePem = pair.privateKey.export({ type: 'pkcs8', format: 'pem' });
    const publicPem = pair.publicKey.export({ type: 'spki', format: 'pem' });
    await writeNew(privatePath, privatePem, 0o600);
    try {
      await writeNew(publicPath, publicPem, 0o644);
    } catch (error) {
      console.error('Public-key output failed; the private key was kept so it can be recovered safely.');
      throw error;
    }
    console.log(`Ed25519 signing key created. Private key is local-only: ${privatePath}`);
    console.log(`Public verification key: ${publicPath}`);
    return;
  }

  const privatePath = path.resolve(options.get('private-key') ?? '');
  const requestPath = path.resolve(options.get('activation-request') ?? '');
  const outputPath = path.resolve(options.get('output') ?? '');
  const customer = options.get('customer')?.trim();
  const days = Number(options.get('days'));
  if (!customer || customer.length > 160 || !Number.isInteger(days) || days < 1 || days > 365 || !requestPath || !outputPath) return usage();

  const request = JSON.parse(await readFile(requestPath, 'utf8'));
  if (
    request.product !== 'Mahabbat' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(request.installation_id ?? '') ||
    !/^[a-f0-9]{64}$/.test(request.machine_fingerprint ?? '')
  ) throw new Error('Activation request is invalid or belongs to another product');

  const issued = new Date();
  const expires = new Date(issued.getTime() + days * 24 * 60 * 60 * 1000);
  const payload = {
    schema_version: 1,
    product: 'Mahabbat',
    customer,
    type: 'pilot',
    installation_id: request.installation_id.toLowerCase(),
    machine_fingerprint: request.machine_fingerprint,
    issued_at: issued.toISOString(),
    expires_at: expires.toISOString(),
    valid_until: expires.toISOString().slice(0, 10),
    duration_days: days,
    features: ['crm', 'pos', 'inventory', 'printing'],
  };

  const privateKey = createPrivateKey(await readFile(privatePath));
  if (privateKey.asymmetricKeyType !== 'ed25519') throw new Error('Signing key must be Ed25519');
  const document = {
    payload,
    signature: sign(null, Buffer.from(canonicalJson(payload), 'utf8'), privateKey).toString('base64'),
  };
  await writeNew(outputPath, `${JSON.stringify(document, null, 2)}\n`, 0o600);
  console.log(`Pilot license issued for ${days} days; expires ${payload.valid_until}.`);
  console.log(`Customer: ${customer}`);
  console.log(`License file: ${outputPath}`);
};

main().catch((error) => {
  console.error(`License operation failed: ${error.message}`);
  process.exitCode = 1;
});
