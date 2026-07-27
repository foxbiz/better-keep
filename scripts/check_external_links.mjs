import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] || 'build/web');
const failures = [];
const deniedStatuses = new Set([401, 403, 429]);

async function collectHtml(directory, prefix = '') {
  const files = [];
  for (const entry of await readdir(directory)) {
    const absolute = path.join(directory, entry);
    const relative = path.join(prefix, entry);
    const info = await stat(absolute);
    if (info.isDirectory()) {
      if (relative === 'app') continue;
      files.push(...(await collectHtml(absolute, relative)));
    } else if (entry.endsWith('.html')) {
      files.push(relative);
    }
  }
  return files;
}

async function check(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    let response = await fetch(url, {
      method: 'HEAD',
      redirect: 'follow',
      signal: controller.signal,
      headers: { 'User-Agent': 'BetterKeep-LinkCheck/1.0' }
    });
    if (!response.ok) {
      response = await fetch(url, {
        method: 'GET',
        redirect: 'follow',
        signal: controller.signal,
        headers: {
          'User-Agent': 'BetterKeep-LinkCheck/1.0',
          Range: 'bytes=0-1024'
        }
      });
    }
    if (!response.ok && !deniedStatuses.has(response.status)) {
      failures.push(`${url} returned HTTP ${response.status}`);
    }
  } catch (error) {
    failures.push(
      `${url} failed: ${error instanceof Error ? error.message : String(error)}`
    );
  } finally {
    clearTimeout(timeout);
  }
}

const links = new Set();
for (const file of await collectHtml(root)) {
  const html = await readFile(path.join(root, file), 'utf8');
  for (const match of html.matchAll(/<a\b[^>]*\bhref="(https:\/\/[^"#]+[^"])"/gi)) {
    links.add(match[1].replaceAll('&amp;', '&'));
  }
}

const queue = [...links];
const workers = Array.from({ length: Math.min(5, queue.length) }, async () => {
  while (queue.length) {
    const url = queue.shift();
    if (url) await check(url);
  }
});
await Promise.all(workers);

if (failures.length) {
  console.error('External link validation failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(`External link validation passed for ${links.size} unique links.`);
