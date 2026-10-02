import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import screenshotCatalog from '../src/data/screenshots.json' with { type: 'json' };
import { screenshotPreviewWidths } from '../src/lib/screenshot-previews.ts';

const scriptPath = fileURLToPath(import.meta.url);
const defaultProjectRoot = path.resolve(path.dirname(scriptPath), '..', '..');
const manropeFontPath = fileURLToPath(
  import.meta.resolve(
    '@fontsource-variable/manrope/files/manrope-latin-wght-normal.woff2'
  )
);

export { screenshotCatalog, screenshotPreviewWidths };
export const GOOGLE_PLAY_BADGE_WIDTH = 564;
export const GOOGLE_PLAY_BADGE_HEIGHT = 168;
export const screenshotIds = Object.freeze(screenshotCatalog.map((item) => item.id));

type Screenshot = typeof screenshotCatalog[number];
const assetCopies: readonly (readonly [string, string])[] = Object.freeze([
  ['web/favicon.ico', 'favicon.ico'],
  ['web/icons/logo.svg', 'media/brand/logo.svg'],
  ['site/assets/brand/app-mark.svg', 'media/brand/app-mark.svg'],
  ['web/icons/logo.png', 'media/brand/logo.png'],
  ['web/icons/ios/512.png', 'media/brand/app-icon-512.png'],
  ['web/icons/ios/180.png', 'media/brand/apple-touch-icon.png'],
  [
    manropeFontPath,
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

async function copyAsset(projectRoot: string, outputRoot: string, [source, destination]: readonly [string, string]) {
  const sourcePath = path.isAbsolute(source)
    ? source
    : path.join(projectRoot, source);
  const destinationPath = path.join(outputRoot, destination);
  await mkdir(path.dirname(destinationPath), { recursive: true });
  await copyFile(sourcePath, destinationPath);
}

async function resetPreparedAssets(outputRoot: string) {
  await Promise.all([
    rm(path.join(outputRoot, 'media'), { recursive: true, force: true }),
    rm(path.join(outputRoot, 'favicon.ico'), { force: true })
  ]);
}

async function prepareGooglePlayBadge(projectRoot: string, outputRoot: string) {
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

function screenshotSource(projectRoot: string, id: string) {
  return path.join(projectRoot, 'site', 'assets', 'screenshots', `${id}.png`);
}

async function validateScreenshot(projectRoot: string, item: Screenshot) {
  const { id, width, height } = item;
  const metadata = await sharp(screenshotSource(projectRoot, id)).metadata();

  if (
    metadata.width !== width ||
    metadata.height !== height
  ) {
    throw new Error(
      `Screenshot ${id}.png is ${metadata.width}x${metadata.height}; expected ${width}x${height}`
    );
  }
}

async function prepareScreenshot(projectRoot: string, outputRoot: string, item: Screenshot) {
  const { id } = item;
  const source = screenshotSource(projectRoot, id);
  const destinationRoot = path.join(outputRoot, 'media', 'screenshots');
  await mkdir(destinationRoot, { recursive: true });
  await Promise.all([
    copyFile(source, path.join(destinationRoot, `${id}.png`)),
    ...screenshotPreviewWidths(item).map((previewWidth) => sharp(source)
      .resize({ width: previewWidth, withoutEnlargement: true })
      .webp({ quality: 82, effort: 6 })
      .toFile(path.join(destinationRoot, `${id}-${previewWidth}.webp`)))
  ]);
}

export async function prepareSiteAssets({
  projectRoot = defaultProjectRoot,
  outputRoot = path.join(projectRoot, 'site', 'public')
} = {}) {
  await Promise.all(screenshotCatalog.map((item) => validateScreenshot(projectRoot, item)));
  await resetPreparedAssets(outputRoot);
  await Promise.all([
    ...assetCopies.map((copy) => copyAsset(projectRoot, outputRoot, copy)),
    prepareGooglePlayBadge(projectRoot, outputRoot),
    ...screenshotCatalog.map((item) => prepareScreenshot(projectRoot, outputRoot, item))
  ]);
}

if (path.resolve(process.argv[1] || '') === scriptPath) {
  await prepareSiteAssets();
  console.log(
    `Prepared ${screenshotIds.length} authentic screenshots and ${assetCopies.length + 1} brand assets.`
  );
}
