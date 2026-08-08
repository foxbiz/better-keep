import { readFile, access, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] || 'build/web');
const failures = [];

async function exists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function read(relativePath) {
  return readFile(path.join(root, relativePath), 'utf8');
}

function assert(condition, message) {
  if (!condition) failures.push(message);
}

function resolveManifestAsset(resource) {
  try {
    const url = new URL(resource, 'https://betterkeep.app/app/manifest.json');
    if (url.origin !== 'https://betterkeep.app') return null;
    const outputPath = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    return outputPath.startsWith(`${root}${path.sep}`) ? outputPath : null;
  } catch {
    return null;
  }
}

const requiredFiles = [
  'index.html',
  '404.html',
  'robots.txt',
  'sitemap.xml',
  'llms.txt',
  'feed.xml',
  'indexnow-key.txt',
  'flutter_service_worker.js',
  'og.png',
  'media/brand/app-icon-512.png',
  'app/index.html',
  'app/manifest.json',
  'auth.html',
  'reset-password.html',
  'desktop-checkout.html',
  's/index.html'
];

for (const file of requiredFiles) {
  assert(await exists(path.join(root, file)), `Missing required output: ${file}`);
}

const index = await read('index.html');
assert(index.includes('<link rel="canonical" href="https://betterkeep.app/"'), 'Homepage canonical is missing');
assert(index.includes('application/ld+json'), 'Homepage structured data is missing');
assert(index.includes('SoftwareApplication'), 'SoftwareApplication schema is missing');
assert(!index.includes('noindex'), 'Homepage must be indexable');
assert(index.includes('https://betterkeep.app/og.png'), 'Homepage social image must be absolute');

const appIndex = await read('app/index.html');
assert(appIndex.includes('<base href="/app/">'), 'Flutter app base href must be /app/');
assert(appIndex.includes('noindex, nofollow'), 'Flutter app index must be noindex');

const legacyServiceWorker = await read('flutter_service_worker.js');
assert(
  legacyServiceWorker.includes('self.registration.unregister()'),
  'Legacy root PWA service worker retirement is missing'
);
assert(
  legacyServiceWorker.includes('flutter-app-cache'),
  'Legacy Flutter cache cleanup is missing'
);

const robots = await read('robots.txt');
assert(robots.includes('User-agent: OAI-SearchBot'), 'robots.txt must cover OAI-SearchBot');
assert(robots.includes('User-agent: PerplexityBot'), 'robots.txt must cover PerplexityBot');
assert(robots.includes('Sitemap: https://betterkeep.app/sitemap.xml'), 'robots.txt sitemap is missing');
assert(!robots.includes('<html'), 'robots.txt returned HTML');

const sitemap = await read('sitemap.xml');
assert(sitemap.includes('<loc>https://betterkeep.app/</loc>'), 'Sitemap homepage is missing');
assert(!sitemap.includes('<priority>'), 'Sitemap must not contain priority');
assert(!sitemap.includes('<changefreq>'), 'Sitemap must not contain changefreq');
assert(!sitemap.includes('/welcome'), 'Sitemap must not contain legacy welcome URLs');
const sitemapLocations = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(
  (match) => match[1]
);
assert(
  sitemapLocations.length === new Set(sitemapLocations).size,
  'Sitemap contains duplicate locations'
);
assert(
  !sitemapLocations.some((location) =>
    /\/(?:app|auth|reset-password|desktop-checkout|s)(?:\/|$)/.test(
      new URL(location).pathname
    )
  ),
  'Sitemap contains a private route'
);
assert(
  [...sitemap.matchAll(/<lastmod>([^<]+)<\/lastmod>/g)].every((match) =>
    /^\d{4}-\d{2}-\d{2}$/.test(match[1])
  ),
  'Sitemap contains an invalid lastmod date'
);

const indexNowKey = (await read('indexnow-key.txt')).trim();
assert(
  /^[a-z0-9-]{8,128}$/i.test(indexNowKey),
  'IndexNow key file is missing or invalid'
);

const manifest = JSON.parse(await read('app/manifest.json'));
assert(manifest.start_url === '/app/', 'PWA start_url must be /app/');
assert(manifest.scope === '/app/', 'PWA scope must be /app/');
assert(
  JSON.stringify((manifest.screenshots || []).map(({ src }) => src)) ===
    JSON.stringify([
      '/media/screenshots/2.png',
      '/media/screenshots/3.png',
      '/media/screenshots/4.png'
    ]),
  'PWA screenshots must reuse the canonical website media URLs'
);
for (const screenshot of manifest.screenshots || []) {
  const assetPath = resolveManifestAsset(screenshot.src);
  assert(
    assetPath && (await exists(assetPath)),
    `Manifest screenshot does not exist: ${screenshot.src}`
  );
}
assert(
  !(await exists(path.join(root, 'app', 'screenshots'))),
  'Hosting bundle contains redundant Flutter screenshot assets'
);
assert(
  !(await exists(path.join(root, 'icons', 'platforms'))) &&
    !(await exists(path.join(root, 'icons', 'store-badges'))),
  'Hosting bundle exposes website-only artwork through the app icon directory'
);

const pagesToCheck = [
  'google-keep-alternative.html',
  'import/google-keep.html',
  'private-encrypted-notes.html',
  'offline-notes-app.html',
  'rich-text-notes.html',
  'voice-notes-transcription.html',
  'cross-platform-notes.html',
  'source-available-notes.html',
  'security.html',
  'changelog.html',
  'compare/standard-notes.html',
  'compare/notesnook.html',
  'compare/joplin.html'
];
const publicPages = [
  'index.html',
  ...pagesToCheck,
  'pricing.html',
  'contact.html',
  'privacy.html',
  'terms.html',
  'cancellation-refund.html',
  'delete-user.html'
];

for (const relativePath of pagesToCheck) {
  const html = await read(relativePath);
  assert(html.includes('rel="canonical"'), `${relativePath} has no canonical`);
  assert(html.includes('BreadcrumbList'), `${relativePath} has no breadcrumb schema`);
  assert(html.includes('Article'), `${relativePath} has no article schema`);
  assert(!html.includes('independently audited</'), `${relativePath} contains an unsupported audit claim`);
}

for (const relativePath of publicPages) {
  const html = await read(relativePath);
  const canonicalCount = [...html.matchAll(/rel="canonical"/g)].length;
  assert(canonicalCount === 1, `${relativePath} must have exactly one canonical`);
  assert(/<title>[^<]+<\/title>/i.test(html), `${relativePath} has no title`);
  assert(
    /<meta\s+name="description"[\s\S]*?content="[^"]+"/i.test(html),
    `${relativePath} has no meta description`
  );
  assert(html.includes('hreflang="en"'), `${relativePath} has no English hreflang`);
  assert(
    html.includes('hreflang="x-default"'),
    `${relativePath} has no x-default hreflang`
  );
  assert(
    /property="og:image"\s+content="https:\/\/betterkeep\.app\//i.test(html) ||
      /property="og:image"\s+content="https:\/\/[^"]+"/i.test(html),
    `${relativePath} social image is not absolute`
  );
  assert(
    html.includes('property="og:image:width" content="1200"'),
    `${relativePath} social image width is missing`
  );
  assert(
    html.includes('property="og:image:height" content="630"'),
    `${relativePath} social image height is missing`
  );

  for (const match of html.matchAll(
    /<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi
  )) {
    try {
      JSON.parse(match[1]);
    } catch (error) {
      failures.push(
        `${relativePath} contains invalid JSON-LD: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }
}

const homepageSchemas = [
  ...index.matchAll(
    /<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi
  )
].map((match) => JSON.parse(match[1]));
const softwareSchema = homepageSchemas.find(
  (schema) => schema['@type'] === 'SoftwareApplication'
);
assert(
  homepageSchemas.some((schema) => schema['@type'] === 'Organization'),
  'Homepage Organization schema is missing'
);
assert(
  homepageSchemas.some((schema) => schema['@type'] === 'WebSite'),
  'Homepage WebSite schema is missing'
);
assert(Boolean(softwareSchema), 'Homepage SoftwareApplication schema is missing');
assert(
  softwareSchema?.offers?.price === '0' &&
    softwareSchema?.offers?.priceCurrency === 'USD',
  'SoftwareApplication must contain the real free-price offer'
);
assert(
  softwareSchema?.applicationCategory === 'UtilitiesApplication',
  'SoftwareApplication category is missing or invalid'
);
assert(
  !('aggregateRating' in (softwareSchema || {})),
  'SoftwareApplication must not fabricate aggregate ratings'
);

for (const relativePath of [
  'app/index.html',
  'auth.html',
  'reset-password.html',
  'desktop-checkout.html',
  's/index.html'
]) {
  const html = await read(relativePath);
  assert(
    /noindex,\s*nofollow/i.test(html),
    `${relativePath} must contain noindex, nofollow`
  );
}

const shareViewer = await read('s/index.html');
assert(
  shareViewer.includes('noindex, nofollow, noarchive'),
  'Shared-note viewer must opt out of indexing and archiving'
);
assert(
  shareViewer.includes('name="referrer" content="no-referrer"'),
  'Shared-note viewer must not leak its fragment-backed URL as a referrer'
);
assert(
  shareViewer.includes('data-share-viewer') &&
    shareViewer.includes('Securely shared through Better Keep'),
  'Shared-note viewer focused shell is missing'
);
assert(
  !/rel="canonical"|plausible\.io/i.test(shareViewer),
  'Shared-note viewer must not contain a canonical URL or analytics'
);
assert(
  !/(?:gstatic\.com\/firebasejs|cdn\.jsdelivr\.net|unpkg\.com)/i.test(
    shareViewer
  ),
  'Shared-note viewer must not load runtime dependencies from a CDN'
);
const shareScripts = [
  ...shareViewer.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/gi)
].map((match) => match[1]);
assert(
  shareScripts.length > 0 &&
    shareScripts.every((source) => source.startsWith('/_astro/')),
  'Shared-note viewer scripts must be locally bundled Astro assets'
);

async function collectHtml(directory, prefix = '') {
  const entries = await readdir(directory);
  const files = [];
  for (const entry of entries) {
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

const htmlFiles = await collectHtml(root);
for (const relativePath of htmlFiles) {
  const html = await read(relativePath);
  const localReferences = [
    ...html.matchAll(/(?:src|href)="(\/[^"#?]+)"/g)
  ].map((match) => match[1]);

  for (const reference of localReferences) {
    const relativeReference = reference.replace(/^\/+|\/+$/g, '');
    const candidates = relativeReference
      ? [
          relativeReference,
          `${relativeReference}.html`,
          path.join(relativeReference, 'index.html')
        ]
      : ['index.html'];
    const resolves = (
      await Promise.all(
        candidates.map((candidate) => exists(path.join(root, candidate)))
      )
    ).some(Boolean);
    assert(resolves, `${relativePath} references missing ${reference}`);
  }
}

if (failures.length) {
  console.error('Visibility validation failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`Visibility validation passed for ${htmlFiles.length} HTML documents.`);
