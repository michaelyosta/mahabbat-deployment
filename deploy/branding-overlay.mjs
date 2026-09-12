// Fail-closed branding overlay for the pinned Twenty v2.29.0 image.
import fs from 'node:fs';
import path from 'node:path';

const front = process.env.BRANDING_FRONT_PATH ?? '/app/packages/twenty-server/dist/front';
const fail = (message) => {
  console.error(`branding-overlay assertion failed: ${message}`);
  process.exit(1);
};

const htmlFile = path.join(front, 'index.html');
let html;
try {
  html = fs.readFileSync(htmlFile, 'utf8');
} catch {
  fail(`cannot read ${htmlFile}`);
}

const replacements = [
  ['A modern open-source CRM', 'MAHABBAT CRM — ресторанная CRM для Казахстана'],
  ['<meta property="og:title" content="Twenty" />', '<meta property="og:title" content="MAHABBAT CRM" />'],
  ['<meta name="twitter:title" content="Twenty" />', '<meta name="twitter:title" content="MAHABBAT CRM" />'],
  ['<title>Twenty</title>', '<title>MAHABBAT CRM</title>'],
  ['https://raw.githubusercontent.com/twentyhq/twenty/main/docs/static/img/social-card.png', ''],
];

for (const [from, to] of replacements) {
  const beforeCount = html.split(from).length - 1;
  if (beforeCount === 0) fail(`target "${from}" not found in index.html`);
  html = html.replaceAll(from, to);
  if (html.includes(from)) fail(`"${from}" still present after replacement`);
  if (to !== '' && !html.includes(to)) fail(`replacement "${to}" missing in index.html after swap`);
}
fs.writeFileSync(htmlFile, html);

const manifestFile = path.join(front, 'manifest.json');
let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
} catch {
  fail(`cannot read or parse ${manifestFile}`);
}
manifest.short_name = 'MAHABBAT';
manifest.name = 'MAHABBAT CRM';
if (manifest.short_name !== 'MAHABBAT' || manifest.name !== 'MAHABBAT CRM') fail('manifest not branded');
fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2));

const assetsDirectory = path.join(front, 'assets');
const assetFiles = fs.readdirSync(assetsDirectory).filter((name) => name.endsWith('.js'));
if (assetFiles.length === 0) fail('no bundled JS assets found to brand');
let brandedAssets = 0;
for (const name of assetFiles) {
  const file = path.join(assetsDirectory, name);
  const before = fs.readFileSync(file, 'utf8');
  const after = before.replaceAll('default:return"Twenty"', 'default:return"MAHABBAT CRM"');
  if (after !== before) {
    fs.writeFileSync(file, after);
    brandedAssets += 1;
  }
}
if (brandedAssets === 0) fail('no bundled JS asset contained the Twenty title token');
console.log(`branding-overlay ok: branded ${brandedAssets}/${assetFiles.length} JS assets`);
