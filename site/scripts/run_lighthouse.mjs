import { createServer } from 'node:http';
import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import lighthouse from 'lighthouse';
import * as chromeLauncher from 'chrome-launcher';

const siteRoot = path.resolve(import.meta.dirname, '..', '..', 'build', 'web');
const reportRoot = path.join(siteRoot, '..', 'lighthouse');
const mimeTypes = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.ico', 'image/x-icon'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml'],
  ['.txt', 'text/plain; charset=utf-8'],
  ['.xml', 'application/xml; charset=utf-8']
]);

async function resolveRequest(urlPath) {
  const decoded = decodeURIComponent(urlPath.split('?')[0]);
  const relative = decoded.replace(/^\/+/, '');
  const candidates = relative
    ? [relative, `${relative}.html`, path.join(relative, 'index.html')]
    : ['index.html'];

  for (const candidate of candidates) {
    const absolute = path.resolve(siteRoot, candidate);
    if (!absolute.startsWith(`${siteRoot}${path.sep}`)) continue;
    try {
      await access(absolute);
      return { absolute, status: 200 };
    } catch {
      // Try the next clean-URL candidate.
    }
  }

  return { absolute: path.join(siteRoot, '404.html'), status: 404 };
}

const server = createServer(async (request, response) => {
  try {
    const { absolute, status } = await resolveRequest(request.url || '/');
    const body = await readFile(absolute);
    const contentType =
      mimeTypes.get(path.extname(absolute).toLowerCase()) ||
      'application/octet-stream';
    response.writeHead(status, {
      'Content-Type': contentType,
      'Cache-Control':
        status === 200 && !contentType.startsWith('text/html')
          ? 'public, max-age=31536000, immutable'
          : 'no-cache'
    });
    response.end(body);
  } catch (error) {
    response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end(error instanceof Error ? error.message : 'Server error');
  }
});

await mkdir(reportRoot, { recursive: true });
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
if (!address || typeof address === 'string') {
  throw new Error('Could not start the Lighthouse fixture server.');
}

const chrome = await chromeLauncher.launch({
  chromeFlags: ['--headless=new', '--no-sandbox', '--disable-gpu']
});
const targets = [
  { path: '/', name: 'home' },
  { path: '/google-keep-alternative', name: 'google-keep-alternative' }
];
const failures = [];

try {
  for (const target of targets) {
    const url = `http://127.0.0.1:${address.port}${target.path}`;
    const result = await lighthouse(url, {
      port: chrome.port,
      output: 'json',
      logLevel: 'error',
      onlyCategories: ['performance', 'accessibility', 'best-practices', 'seo'],
      blockedUrlPatterns: ['https://plausible.io/*']
    });
    if (!result) throw new Error(`Lighthouse returned no result for ${url}`);

    await writeFile(
      path.join(reportRoot, `${target.name}.json`),
      JSON.stringify(result.lhr, null, 2)
    );

    const categories = result.lhr.categories;
    const scores = {
      performance: categories.performance.score ?? 0,
      accessibility: categories.accessibility.score ?? 0,
      bestPractices: categories['best-practices'].score ?? 0,
      seo: categories.seo.score ?? 0
    };
    const thresholds = {
      performance: 0.9,
      accessibility: 0.95,
      bestPractices: 0.95,
      seo: 0.95
    };

    for (const [category, score] of Object.entries(scores)) {
      if (score < thresholds[category]) {
        failures.push(
          `${target.name}: ${category} scored ${Math.round(score * 100)}; expected ${Math.round(thresholds[category] * 100)}`
        );
      }
    }

    const lcp = result.lhr.audits['largest-contentful-paint']?.numericValue;
    const cls = result.lhr.audits['cumulative-layout-shift']?.numericValue;
    const tbt = result.lhr.audits['total-blocking-time']?.numericValue;
    if (typeof lcp === 'number' && lcp > 2500) {
      failures.push(`${target.name}: lab LCP ${Math.round(lcp)}ms exceeds 2500ms`);
    }
    if (typeof cls === 'number' && cls > 0.1) {
      failures.push(`${target.name}: lab CLS ${cls.toFixed(3)} exceeds 0.1`);
    }
    if (typeof tbt === 'number' && tbt > 200) {
      failures.push(`${target.name}: lab TBT ${Math.round(tbt)}ms exceeds 200ms`);
    }

    console.log(
      `${target.name}: performance ${Math.round(scores.performance * 100)}, accessibility ${Math.round(scores.accessibility * 100)}, best practices ${Math.round(scores.bestPractices * 100)}, SEO ${Math.round(scores.seo * 100)}`
    );
  }
} finally {
  chrome.kill();
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve()))
  );
}

if (failures.length) {
  console.error('Lighthouse validation failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(`Lighthouse reports written to ${reportRoot}.`);
