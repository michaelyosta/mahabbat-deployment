import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [innerRootArg, outputPathArg] = process.argv.slice(2);
if (!innerRootArg || !outputPathArg) throw new Error('Usage: node build-pilot-app-installer.mjs <inner-repo> <output-file>');

const innerRoot = path.resolve(innerRootArg);
const outputPath = path.resolve(outputPathArg);
const requireFromInner = createRequire(path.join(innerRoot, 'package.json'));
const { build } = requireFromInner('esbuild');

await build({
  absWorkingDir: repositoryRoot,
  entryPoints: [path.join(repositoryRoot, 'tools', 'pilot-app-installer.mjs')],
  outfile: outputPath,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node24',
  minify: true,
  sourcemap: false,
  // Keep third-party copyright/license comments in a sibling .LEGAL.txt notice.
  legalComments: 'external',
  nodePaths: [path.join(innerRoot, 'node_modules')],
  logLevel: 'info',
});

console.log('PILOT_APP_INSTALLER_BUNDLE=PASS');
