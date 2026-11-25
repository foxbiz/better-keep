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
const download = await readFile(
  path.join(siteRoot, 'src/components/DownloadSection.astro'),
  'utf8'
);

function blockAfter(source: string, marker: string) {
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

test('mobile hero puts the download actions before one tall video', () => {
  const video = blockAfter(mobile, '.hero-video');

  assert.match(video, /width:\s*min\(82vw, 340px\)/);
  assert.match(video, /aspect-ratio:\s*9 \/ 16/);
  assert.equal((hero.match(/<video/g) || []).length, 1);
  assert.ok(hero.indexOf('<StoreActions') < hero.indexOf('<UserCount'));
  assert.ok(hero.indexOf('<UserCount') < hero.indexOf('<video'));
  assert.match(hero, /layout: 'tall', media: narrow/);
});

test('the floating action yields to the page download actions', () => {
  assert.match(hero, /data-download-actions/);
  assert.match(download, /data-download-actions/);
  const rule = blockAfter(
    css,
    "body:has([data-download-actions]) .floating-web-app:not([data-hidden='false'])"
  );
  assert.match(rule, /visibility:\s*hidden/);
});

test('homepage density and tap targets remain responsive at narrow widths', () => {
  const platformGrid = blockAfter(mobile, '.platform-grid');
  const narrowPlatformGrid = blockAfter(narrow, '.platform-grid');
  const githubBadge = blockAfter(css, '.nav-github');
  const menuToggle = blockAfter(css, '.mobile-menu-toggle');
  const storeBadge = blockAfter(css, '.web-app-action,\n.store-badge');

  assert.match(platformGrid, /repeat\(2, minmax\(0, 1fr\)\)/);
  assert.match(narrowPlatformGrid, /grid-template-columns:\s*1fr/);
  assert.match(githubBadge, /min-height:\s*44px/);
  assert.match(menuToggle, /height:\s*46px/);
  assert.match(storeBadge, /height:\s*52px/);
  assert.match(mobile, /\.home-section\s*\{[\s\S]*?padding-block:\s*4rem/);
  assert.match(blockAfter(css, '.hero-video__controls button'), /height:\s*44px/);
  assert.match(
    blockAfter(blockAfter(css, '@media (max-width: 920px)'), '.security-story__device'),
    /display:\s*none/
  );
});

test('mobile store actions use container-aware centering', () => {
  const storeActions = blockAfter(mobile, '.store-actions');

  assert.match(storeActions, /width:\s*min\(328px, 100%\)/);
  assert.match(storeActions, /margin-inline:\s*auto/);
  assert.doesNotMatch(storeActions, /(?:position|left|transform):/);
});
