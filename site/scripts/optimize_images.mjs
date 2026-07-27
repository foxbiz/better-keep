import { copyFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const projectRoot = path.resolve(import.meta.dirname, '..', '..');
const outputRoot = path.join(
  projectRoot,
  'site',
  'public',
  'media',
  'screenshots'
);
const screenshotIds = ['1', '2', '3', '4', '5', '6', '7'];

await mkdir(outputRoot, { recursive: true });

await Promise.all(
  screenshotIds.map(async (id) => {
    const source = path.join(projectRoot, 'web', 'screenshots', `${id}.png`);
    const destination = path.join(outputRoot, `${id}-480.webp`);
    await Promise.all([
      copyFile(source, path.join(outputRoot, `${id}.png`)),
      sharp(source)
        .resize({ width: 480, withoutEnlargement: true })
        .webp({ quality: 78, effort: 6 })
        .toFile(destination)
    ]);
  })
);

console.log(`Optimized ${screenshotIds.length} website screenshots.`);
