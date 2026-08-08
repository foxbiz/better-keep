import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const projectRoot = path.resolve(import.meta.dirname, '..');
const sitemapPath = path.join(projectRoot, 'build', 'web', 'sitemap.xml');
const keyPath = path.join(
  projectRoot,
  'site',
  'public',
  'indexnow-key.txt'
);
const key = (await readFile(keyPath, 'utf8')).trim();
const sitemap = await readFile(sitemapPath, 'utf8');
const urlList = [...sitemap.matchAll(/<loc>(https:\/\/betterkeep\.app\/[^<]*)<\/loc>/g)]
  .map((match) => match[1])
  .slice(0, 10_000);

if (!/^[a-z0-9-]{8,128}$/i.test(key)) {
  throw new Error('The IndexNow key must contain 8–128 URL-safe characters.');
}
if (!urlList.length) {
  throw new Error('No Better Keep URLs were found in build/web/sitemap.xml.');
}

const payload = {
  host: 'betterkeep.app',
  key,
  keyLocation: 'https://betterkeep.app/indexnow-key.txt',
  urlList
};

if (process.argv.includes('--dry-run')) {
  console.log(JSON.stringify(payload, null, 2));
  process.exit(0);
}

const response = await fetch('https://api.indexnow.org/indexnow', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json; charset=utf-8' },
  body: JSON.stringify(payload)
});

if (![200, 202].includes(response.status)) {
  throw new Error(
    `IndexNow returned HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`
  );
}

console.log(`IndexNow accepted ${urlList.length} Better Keep URLs.`);
