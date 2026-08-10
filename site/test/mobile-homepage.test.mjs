import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const css = await readFile(path.join(siteRoot, 'src/styles/global.css'), 'utf8');
const hero = await readFile(
  path.join(siteRoot, 'src/components/HomeHero.astro'),
  'utf8'
);
const gallery = await readFile(
  path.join(siteRoot, 'src/components/ScreenshotRail.astro'),
  'utf8'
);

function blockAfter(source, marker) {
  const markerIndex = source.indexOf(marker);
  assert.notEqual(markerIndex, -1, `Missing CSS marker: ${marker}`);
  const openIndex = source.indexOf('{', markerIndex + marker.length);
  assert.notEqual(openIndex, -1, `Missing opening brace after: ${marker}`);
  let depth = 0;
  for (let index = openIndex; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(openIndex + 1, index);
  }
  throw new Error(`Missing closing brace after: ${marker}`);
}

const mobile = blockAfter(css, '@media (max-width: 680px)');
const narrow = blockAfter(css, '@media (max-width: 359px)');

test('mobile hero uses one bounded phone in front of a true circular halo', () => {
  const backdrop = blockAfter(mobile, '.hero-stage__backdrop');
  const primary = blockAfter(mobile, '.hero-device--primary');
  const sideDevices = blockAfter(
    mobile,
    '.hero-device--left,\n  .hero-device--right'
  );

  assert.match(backdrop, /aspect-ratio:\s*1\s*;/);
  assert.match(backdrop, /width:\s*min\(84vw, 340px\)/);
  assert.match(backdrop, /height:\s*auto/);
  assert.match(backdrop, /transform:\s*translateX\(-50%\)/);
  assert.doesNotMatch(backdrop, /inset:\s*10% 4% 4%/);
  assert.match(primary, /width:\s*clamp\(210px, 64vw, 250px\)/);
  assert.match(sideDevices, /display:\s*none/);
  assert.equal((hero.match(/heroScreenshots\.map/g) || []).length, 1);
  assert.equal((hero.match(/<DeviceFrame/g) || []).length, 1);
});

test('mobile screenshot gallery is a native accessible scroll-snap rail', () => {
  const galleryRule = blockAfter(mobile, '.device-gallery');
  const galleryItemRule = blockAfter(mobile, '.device-gallery__item');

  assert.match(galleryRule, /grid-auto-flow:\s*column/);
  assert.match(galleryRule, /overflow-x:\s*auto/);
  assert.match(galleryRule, /scroll-snap-type:\s*x mandatory/);
  assert.match(galleryItemRule, /scroll-snap-align:\s*start/);
  assert.match(galleryItemRule, /scroll-snap-stop:\s*always/);
  assert.match(gallery, /Swipe to explore the app screens/);
  assert.match(gallery, /role="region"/);
  assert.match(gallery, /tabindex="0"/);
  assert.equal((gallery.match(/galleryScreenshots\.map/g) || []).length, 1);
  assert.doesNotMatch(gallery, /<script|onclick|addEventListener/);
});

test('homepage density and tap targets remain responsive at narrow widths', () => {
  const platformGrid = blockAfter(mobile, '.platform-grid');
  const narrowPlatformGrid = blockAfter(narrow, '.platform-grid');
  const githubBadge = blockAfter(css, '.hero-github-badge');
  const menuToggle = blockAfter(css, '.mobile-menu-toggle');
  const storeBadge = blockAfter(css, '.web-app-action,\n.store-badge');

  assert.match(platformGrid, /repeat\(2, minmax\(0, 1fr\)\)/);
  assert.match(narrowPlatformGrid, /grid-template-columns:\s*1fr/);
  assert.match(githubBadge, /min-height:\s*44px/);
  assert.match(menuToggle, /height:\s*46px/);
  assert.match(storeBadge, /height:\s*52px/);
  assert.match(mobile, /\.home-section\s*\{[\s\S]*?padding-block:\s*4rem/);
  assert.match(mobile, /\.security-story__device\s*\{[\s\S]*?min\(66vw, 240px\)/);
});
