import assert from 'node:assert/strict';
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import test from 'node:test';
import {
  GOOGLE_PLAY_BADGE_HEIGHT,
  GOOGLE_PLAY_BADGE_WIDTH,
  OPTIMIZED_SCREENSHOT_WIDTH,
  SCREENSHOT_HEIGHT,
  SCREENSHOT_WIDTH,
  prepareSiteAssets,
  screenshotIds
} from '../site/scripts/prepare_assets.mjs';

const requireFromSite = createRequire(
  path.resolve('site', 'package.json')
);
const sharp = requireFromSite('sharp');

const expectedStaticAssetOutputs = Object.freeze([
  'favicon.ico',
  'media/brand/logo.svg',
  'media/brand/app-mark.svg',
  'media/brand/logo.png',
  'media/brand/app-icon-512.png',
  'media/brand/apple-touch-icon.png',
  'media/fonts/manrope-latin-wght-normal.woff2',
  'media/platforms/apple.svg',
  'media/platforms/android.svg',
  'media/platforms/github.svg',
  'media/platforms/windows.svg',
  'media/platforms/web-globe.svg',
  'media/store-badges/app-store.svg',
  'media/store-badges/google-play.png',
  'media/store-badges/microsoft-store.svg'
]);

const expectedPreparedAssets = Object.freeze([
  ...expectedStaticAssetOutputs,
  ...screenshotIds.flatMap((id) => [
    `media/screenshots/${id}.png`,
    `media/screenshots/${id}-480.webp`
  ])
]);

async function alphaBounds(file) {
  const { data, info } = await sharp(file)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  let left = info.width;
  let top = info.height;
  let right = -1;
  let bottom = -1;

  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      if (data[(y * info.width + x) * 4 + 3] === 0) continue;
      left = Math.min(left, x);
      top = Math.min(top, y);
      right = Math.max(right, x);
      bottom = Math.max(bottom, y);
    }
  }
  return { bottom, left, right, top };
}

test('keeps website-owned source assets inside site/assets', async () => {
  const expectedSources = [
    'brand/app-mark.svg',
    'platforms/SOURCES.md',
    'platforms/apple.svg',
    'platforms/android.svg',
    'platforms/github.svg',
    'platforms/windows.svg',
    'platforms/web.svg',
    'store-badges/SOURCES.md',
    'store-badges/app-store.svg',
    'store-badges/google-play.png',
    'store-badges/microsoft-store.svg',
    ...Array.from({ length: 7 }, (_, index) => `screenshots/${index + 1}.png`)
  ];

  await Promise.all(
    expectedSources.map((asset) => access(path.resolve('site', 'assets', asset)))
  );

  const forbiddenWebSources = [
    'web/screenshots',
    'web/icons/platforms',
    'web/icons/store-badges',
    'web/icons/logo_with_bg.svg',
    'web/sitemap.xml'
  ];
  for (const asset of forbiddenWebSources) {
    await assert.rejects(access(path.resolve(asset)), { code: 'ENOENT' });
  }
});

test('prepares authentic screenshots without changing their proportions', async () => {
  const outputRoot = await mkdtemp(path.join(tmpdir(), 'better-keep-site-assets-'));
  await prepareSiteAssets({ projectRoot: process.cwd(), outputRoot });

  for (const id of screenshotIds) {
    const original = await sharp(
      path.join(outputRoot, 'media', 'screenshots', `${id}.png`)
    ).metadata();
    const optimized = await sharp(
      path.join(outputRoot, 'media', 'screenshots', `${id}-480.webp`)
    ).metadata();

    assert.equal(original.width, SCREENSHOT_WIDTH);
    assert.equal(original.height, SCREENSHOT_HEIGHT);
    assert.equal(optimized.width, OPTIMIZED_SCREENSHOT_WIDTH);
    assert.ok(
      Math.abs(
        optimized.height / optimized.width - SCREENSHOT_HEIGHT / SCREENSHOT_WIDTH
      ) < 0.002,
      `${id}-480.webp changed the screenshot aspect ratio`
    );
  }
});

test('removes only stale generated assets before preparing a complete output set', async () => {
  const outputRoot = await mkdtemp(path.join(tmpdir(), 'better-keep-site-clean-'));
  const staleAsset = path.join(outputRoot, 'media', 'platforms', 'obsolete.svg');
  const preservedFiles = new Map([
    ['og.png', 'preserved Open Graph image'],
    ['flutter_service_worker.js', 'preserved legacy worker'],
    ['indexnow-key.txt', 'preserved IndexNow key']
  ]);

  await mkdir(path.dirname(staleAsset), { recursive: true });
  await Promise.all([
    writeFile(staleAsset, 'obsolete generated output'),
    ...[...preservedFiles].map(([file, contents]) =>
      writeFile(path.join(outputRoot, file), contents)
    )
  ]);

  await prepareSiteAssets({ projectRoot: process.cwd(), outputRoot });

  await assert.rejects(access(staleAsset), { code: 'ENOENT' });
  await Promise.all(
    expectedPreparedAssets.map((asset) => access(path.join(outputRoot, asset)))
  );
  for (const [file, contents] of preservedFiles) {
    assert.equal(await readFile(path.join(outputRoot, file), 'utf8'), contents);
  }
});

test('copies local brand, platform, and official store artwork', async () => {
  const outputRoot = await mkdtemp(path.join(tmpdir(), 'better-keep-site-brand-'));
  await prepareSiteAssets({ projectRoot: process.cwd(), outputRoot });

  await Promise.all(
    expectedStaticAssetOutputs.map((asset) => access(path.join(outputRoot, asset)))
  );
  assert.match(
    await readFile(path.join(outputRoot, 'media', 'store-badges', 'app-store.svg'), 'utf8'),
    /Download_on_the_App_Store/
  );
  assert.match(
    await readFile(path.join(outputRoot, 'media', 'store-badges', 'microsoft-store.svg'), 'utf8'),
    /<svg/
  );
  const platformColors = new Map([
    ['apple.svg', '#FFFFFF'],
    ['android.svg', '#3DDC84'],
    ['github.svg', '#181717'],
    ['windows.svg', '#0078D4'],
    ['web-globe.svg', '#E7FF00']
  ]);
  for (const [asset, color] of platformColors) {
    const svg = await readFile(
      path.join(outputRoot, 'media', 'platforms', asset),
      'utf8'
    );
    assert.match(svg, /<svg/);
    assert.ok(svg.includes(color), `${asset} is missing ${color}`);
  }
});

test('trims only the transparent Google Play badge canvas', async () => {
  const outputRoot = await mkdtemp(path.join(tmpdir(), 'better-keep-store-badge-'));
  await prepareSiteAssets({ projectRoot: process.cwd(), outputRoot });

  const source = path.resolve(
    'site',
    'assets',
    'store-badges',
    'google-play.png'
  );
  const prepared = path.join(
    outputRoot,
    'media',
    'store-badges',
    'google-play.png'
  );
  const metadata = await sharp(prepared).metadata();
  assert.equal(metadata.width, GOOGLE_PLAY_BADGE_WIDTH);
  assert.equal(metadata.height, GOOGLE_PLAY_BADGE_HEIGHT);
  assert.deepEqual(await alphaBounds(prepared), {
    bottom: GOOGLE_PLAY_BADGE_HEIGHT - 1,
    left: 0,
    right: GOOGLE_PLAY_BADGE_WIDTH - 1,
    top: 0
  });

  const sourceBounds = await alphaBounds(source);
  assert.deepEqual(sourceBounds, { bottom: 208, left: 41, right: 604, top: 41 });
  const expectedPixels = await sharp(source)
    .extract({
      left: sourceBounds.left,
      top: sourceBounds.top,
      width: GOOGLE_PLAY_BADGE_WIDTH,
      height: GOOGLE_PLAY_BADGE_HEIGHT
    })
    .ensureAlpha()
    .raw()
    .toBuffer();
  const preparedPixels = await sharp(prepared).ensureAlpha().raw().toBuffer();
  assert.equal(preparedPixels.length, expectedPixels.length);
  for (let offset = 0; offset < preparedPixels.length; offset += 4) {
    if (expectedPixels[offset + 3] === 0) continue;
    assert.deepEqual(
      preparedPixels.subarray(offset, offset + 4),
      expectedPixels.subarray(offset, offset + 4),
      `Visible Google Play badge pixel changed at offset ${offset}`
    );
  }
});
