import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const scriptPath = fileURLToPath(import.meta.url);
const defaultProjectRoot = path.resolve(path.dirname(scriptPath), '..', '..');

export const SCREENSHOT_WIDTH = 1179;
export const SCREENSHOT_HEIGHT = 2556;
export const OPTIMIZED_SCREENSHOT_WIDTH = 480;
export const GOOGLE_PLAY_BADGE_WIDTH = 564;
export const GOOGLE_PLAY_BADGE_HEIGHT = 168;
export const screenshotIds = Object.freeze(['1', '2', '3', '4', '5', '6', '7']);

const assetCopies = Object.freeze([
  ['web/favicon.ico', 'favicon.ico'],
  ['web/icons/logo.svg', 'media/brand/logo.svg'],
  ['site/assets/brand/app-mark.svg', 'media/brand/app-mark.svg'],
  ['web/icons/logo.png', 'media/brand/logo.png'],
  ['web/icons/ios/512.png', 'media/brand/app-icon-512.png'],
  ['web/icons/ios/180.png', 'media/brand/apple-touch-icon.png'],
  [
    'site/node_modules/@fontsource-variable/manrope/files/manrope-latin-wght-normal.woff2',
    'media/fonts/manrope-latin-wght-normal.woff2'
  ],
  ['site/assets/platforms/apple.svg', 'media/platforms/apple.svg'],
  ['site/assets/platforms/android.svg', 'media/platforms/android.svg'],
  ['site/assets/platforms/github.svg', 'media/platforms/github.svg'],
  ['site/assets/platforms/windows.svg', 'media/platforms/windows.svg'],
  ['site/assets/platforms/web.svg', 'media/platforms/web-globe.svg'],
  ['site/assets/store-badges/app-store.svg', 'media/store-badges/app-store.svg'],
  [
    'site/assets/store-badges/microsoft-store.svg',
    'media/store-badges/microsoft-store.svg'
  ]
]);

async function copyAsset(projectRoot, outputRoot, [source, destination]) {
  const sourcePath = path.join(projectRoot, source);
  const destinationPath = path.join(outputRoot, destination);
  await mkdir(path.dirname(destinationPath), { recursive: true });
  await copyFile(sourcePath, destinationPath);
}

async function resetPreparedAssets(outputRoot) {
  await Promise.all([
    rm(path.join(outputRoot, 'media'), { recursive: true, force: true }),
    rm(path.join(outputRoot, 'favicon.ico'), { force: true })
  ]);
}

async function prepareGooglePlayBadge(projectRoot, outputRoot) {
  const source = path.join(
    projectRoot,
    'site',
    'assets',
    'store-badges',
    'google-play.png'
  );
  const destination = path.join(
    outputRoot,
    'media',
    'store-badges',
    'google-play.png'
  );
  await mkdir(path.dirname(destination), { recursive: true });
  const result = await sharp(source).trim().png().toFile(destination);

  if (
    result.width !== GOOGLE_PLAY_BADGE_WIDTH ||
    result.height !== GOOGLE_PLAY_BADGE_HEIGHT
  ) {
    throw new Error(
      `Prepared Google Play badge is ${result.width}x${result.height}; expected ${GOOGLE_PLAY_BADGE_WIDTH}x${GOOGLE_PLAY_BADGE_HEIGHT}`
    );
  }
}

async function prepareScreenshot(projectRoot, outputRoot, id) {
  const source = path.join(
    projectRoot,
    'site',
    'assets',
    'screenshots',
    `${id}.png`
  );
  const destinationRoot = path.join(outputRoot, 'media', 'screenshots');
  const metadata = await sharp(source).metadata();

  if (
    metadata.width !== SCREENSHOT_WIDTH ||
    metadata.height !== SCREENSHOT_HEIGHT
  ) {
    throw new Error(
      `Screenshot ${id}.png is ${metadata.width}x${metadata.height}; expected ${SCREENSHOT_WIDTH}x${SCREENSHOT_HEIGHT}`
    );
  }

  await mkdir(destinationRoot, { recursive: true });
  await Promise.all([
    copyFile(source, path.join(destinationRoot, `${id}.png`)),
    sharp(source)
      .resize({ width: OPTIMIZED_SCREENSHOT_WIDTH, withoutEnlargement: true })
      .webp({ quality: 82, effort: 6 })
      .toFile(path.join(destinationRoot, `${id}-480.webp`))
  ]);
}

export async function prepareSiteAssets({
  projectRoot = defaultProjectRoot,
  outputRoot = path.join(projectRoot, 'site', 'public')
} = {}) {
  await resetPreparedAssets(outputRoot);
  await Promise.all([
    ...assetCopies.map((copy) => copyAsset(projectRoot, outputRoot, copy)),
    prepareGooglePlayBadge(projectRoot, outputRoot),
    ...screenshotIds.map((id) => prepareScreenshot(projectRoot, outputRoot, id))
  ]);
}

if (path.resolve(process.argv[1] || '') === scriptPath) {
  await prepareSiteAssets();
  console.log(
    `Prepared ${screenshotIds.length} authentic screenshots and ${assetCopies.length + 1} brand assets.`
  );
}
