import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const workspaceRoot = path.resolve(path.dirname(scriptPath), '..');
const projectRoot = path.resolve(workspaceRoot, '..');
const outputRoot = path.join(workspaceRoot, 'public');
const manropeFontPath = fileURLToPath(
  import.meta.resolve('@fontsource-variable/manrope/files/manrope-latin-wght-normal.woff2')
);

const copies = Object.freeze([
  [path.join(projectRoot, 'web', 'favicon.ico'), 'favicon.ico'],
  [path.join(projectRoot, 'site', 'assets', 'brand', 'app-mark.svg'), 'media/brand/app-mark.svg'],
  [path.join(projectRoot, 'web', 'icons', 'ios', '180.png'), 'media/brand/apple-touch-icon.png'],
  [manropeFontPath, 'media/fonts/manrope-latin-wght-normal.woff2']
]);

export async function prepareAdminAssets() {
  await rm(outputRoot, { recursive: true, force: true });
  for (const [source, destination] of copies) {
    const output = path.join(outputRoot, destination);
    await mkdir(path.dirname(output), { recursive: true });
    await copyFile(source, output);
  }
}

if (path.resolve(process.argv[1] || '') === scriptPath) {
  await prepareAdminAssets();
  console.log(`Prepared ${copies.length} isolated admin assets.`);
}
