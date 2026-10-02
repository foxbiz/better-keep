import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import screenshotCatalog from '../src/data/screenshots.json' with { type: 'json' };
import { screenshotPreviewWidths } from './prepare_assets.ts';

const siteRoot = path.resolve(import.meta.dirname, '..');
const outputRoot = path.join(siteRoot, 'dist');
const failures: string[] = [];

function assert(condition: unknown, message: string) {
  if (!condition) failures.push(message);
}

async function exists(relativePath: string) {
  try {
    await access(path.join(outputRoot, relativePath));
    return true;
  } catch {
    return false;
  }
}

async function collectHtml(directory: string, prefix = ''): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    const relative = path.join(prefix, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await collectHtml(absolute, relative)));
    } else if (entry.name.endsWith('.html')) {
      files.push(relative);
    }
  }
  return files;
}

function visibleText(html: string) {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&copy;|©/g, ' ')
    .replace(/\s+/g, ' ');
}

const index = await readFile(path.join(outputRoot, 'index.html'), 'utf8');
const sourceCss = await readFile(
  path.join(siteRoot, 'src', 'styles', 'global.css'),
  'utf8'
);
const headerSource = await readFile(
  path.join(siteRoot, 'src', 'components', 'Header.astro'),
  'utf8'
);
const homeHeroSource = await readFile(
  path.join(siteRoot, 'src', 'components', 'HomeHero.astro'),
  'utf8'
);
const storeActionsSource = await readFile(
  path.join(siteRoot, 'src', 'components', 'StoreActions.astro'),
  'utf8'
);
const userCountSource = await readFile(
  path.join(siteRoot, 'src', 'components', 'UserCount.astro'),
  'utf8'
);
const publicStatsSource = await readFile(
  path.join(siteRoot, 'src', 'lib', 'public-stats.ts'),
  'utf8'
);
const baseLayoutSource = await readFile(
  path.join(siteRoot, 'src', 'layouts', 'BaseLayout.astro'),
  'utf8'
);
const notFoundSource = await readFile(
  path.join(siteRoot, 'src', 'pages', '404.astro'),
  'utf8'
);
const notFoundHtml = await readFile(path.join(outputRoot, '404.html'), 'utf8');
const indexVisibleText = visibleText(index);
const requiredHomepageCopy = [
  'Private, offline-friendly notes',
  'Write, organize, and find',
  'For lists, plans, and longer notes.',
  'Protect private notes across approved devices.',
  'Inside Better Keep',
  'Take a look inside the app.',
  'Write in tables, make nested checklists, record voice notes, and choose a theme you like.',
  'Start with free notes. Add sync with Pro.'
];
const removedMetaMarketingCopy = [
  'A calmer place for everything worth keeping',
  'Built for actual note-taking',
  'More capable. Never heavier.',
  'Your notes are useful because they are personal.',
  'The real app',
  'No mockups. No invented interface.',
  'Every screen shown here comes from Better Keep itself',
  'Authentic Better Keep interface from the current app.',
  'Keep the familiar flow. Upgrade everything around it.'
];
const expectedScreenshotCaptions = Object.fromEntries(screenshotCatalog.map((item) => [item.id, item.caption]));
const expectedFeatureIcons = [
  'text-cursor-input',
  'shield-check',
  'cloud-off',
  'monitor-smartphone',
  'folders',
  'audio-waveform'
];

assert(
  (index.match(/class="feature-row"/g) || []).length === 6,
  'Homepage must render exactly six primary feature rows'
);

for (const copy of requiredHomepageCopy) {
  assert(
    indexVisibleText.includes(copy),
    `Homepage is missing concrete product copy: “${copy}”`
  );
}

for (const icon of expectedFeatureIcons) {
  assert(
    index.includes(`lucide-${icon}`),
    `Homepage is missing configured SVG icon: ${icon}`
  );
}

assert(
  !index.includes('>Open Source<'),
  'Homepage contains the unsupported Open Source label'
);
assert(
  !/thousands of users/i.test(index),
  'Homepage contains an unverified user-count claim'
);
assert(
  index.includes('Source-available'),
  'Homepage source-available wording is missing'
);
assert(
  headerSource.includes('class="nav-github"') &&
    headerSource.includes('aria-label="View Better Keep on GitHub"') &&
    headerSource.includes('data-analytics={product.analyticsGoals.github}') &&
    !homeHeroSource.includes('hero-github-badge') &&
    !homeHeroSource.includes('class="hero-proof"') &&
    !homeHeroSource.includes('platforms-note') &&
    homeHeroSource.includes('home-hero__community'),
  'GitHub must be an accessible header icon, with only the anchored community count retained in the hero'
);
assert(
  index.includes('data-user-count') &&
    index.includes('data-state="idle"') &&
    index.includes('role="status"') &&
    index.includes('aria-live="polite"') &&
    index.includes('aria-busy="true"') &&
    index.includes('user-count-proof__spinner') &&
    index.includes('People have joined') &&
    index.includes('lucide-users'),
  'Homepage is missing the accessible community-count loading state'
);
assert(
  index.includes('class="home-hero__community"'),
  'Registered-user metric must have a dedicated anchored position in the hero'
);
assert(
  !/\d+(?:\.\d)?[KM]\+\s+people have joined/i.test(indexVisibleText) &&
    !/4200\+|4500\+/.test(indexVisibleText),
  'Homepage must not hard-code a community count'
);
const userCountMetricRule =
  sourceCss.match(/\.user-count-proof__metric\s*\{([^}]*)\}/)?.[1] || '';
const userCountSpinnerRule =
  sourceCss.match(/\.user-count-proof__spinner\s*\{([^}]*)\}/)?.[1] || '';
assert(
  /width:\s*2\.5rem/.test(userCountMetricRule) &&
    /flex:\s*0 0 2\.5rem/.test(userCountMetricRule) &&
    /font-variant-numeric:\s*tabular-nums/.test(userCountMetricRule) &&
    /animation:\s*user-count-spin/.test(userCountSpinnerRule) &&
    sourceCss.includes(".user-count-proof[data-state='idle']") &&
    sourceCss.includes('.user-count-proof__metric[hidden]') &&
    sourceCss.includes('.user-count-proof__spinner {\n    animation: none !important;'),
  'User-count metric must reserve space, collapse its fallback gap, and provide a reduced-motion-safe loader'
);
assert(
  userCountSource.includes('loadPublicUserMetric') &&
    userCountSource.includes('createUserCountPresentation') &&
    userCountSource.includes('data-user-count-label') &&
    userCountSource.includes('metric.hidden = presentation.metric === null') &&
    !userCountSource.includes('counter.hidden = true') &&
    publicStatsSource.includes('timeoutMs = 3000') &&
    publicStatsSource.includes('maxAttempts = 2') &&
    publicStatsSource.includes('retryDelayMs = 250') &&
    publicStatsSource.includes("label: 'Growing community'") &&
    publicStatsSource.includes("record.metric") &&
    publicStatsSource.includes("record.message"),
  'User-count client must support retry, a stable neutral fallback, and legacy responses'
);
assert(
  sourceCss.includes('@media (prefers-reduced-motion: reduce)'),
  'Design system does not include reduced-motion handling'
);
assert(
  sourceCss.includes(':focus-visible'),
  'Design system does not include a visible keyboard focus treatment'
);
assert(
  index.includes('aria-controls="mobile-navigation"') &&
    index.includes('aria-expanded="false"'),
  'Mobile navigation accessibility state is missing'
);
assert(
  headerSource.includes("event.key !== 'Tab'") &&
    headerSource.includes('returnFocus?.focus()'),
  'Mobile navigation does not contain focus or restore its trigger'
);
const mobileNavigationRule =
  sourceCss.match(/\.mobile-navigation\s*\{([^}]*)\}/)?.[1] || '';
const mobileNavigationLinksRule =
  sourceCss.match(/\.mobile-navigation__links\s*\{([^}]*)\}/)?.[1] || '';
const narrowMobileNavigationRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*860px\)[\s\S]*?\.mobile-navigation\s*\{([^}]*)\}/
  )?.[1] || '';
const mobileHeroDecorationRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*920px\)[\s\S]*?\.home-hero::before\s*\{([^}]*)\}/
  )?.[1] || '';
const narrowHeroStageRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*680px\)[\s\S]*?\.hero-stage\s*\{([^}]*)\}/
  )?.[1] || '';
const narrowHeroPrimaryDeviceRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*680px\)[\s\S]*?\.hero-device--primary\s*\{([^}]*)\}/
  )?.[1] || '';
const narrowDocumentTableRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*680px\)[\s\S]*?\.document-body table\s*\{([^}]*)\}/
  )?.[1] || '';
const notFoundRule = sourceCss.match(/\.not-found\s*\{([^}]*)\}/)?.[1] || '';
const narrowNotFoundRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*860px\)[\s\S]*?\.not-found\s*\{([^}]*)\}/
  )?.[1] || '';
assert(
  /position:\s*absolute/.test(mobileNavigationRule) &&
    /top:\s*100%/.test(mobileNavigationRule) &&
    /height:\s*calc\(100dvh - 76px\)/.test(mobileNavigationRule) &&
    /overflow-y:\s*auto/.test(mobileNavigationRule) &&
    /overscroll-behavior:\s*contain/.test(mobileNavigationRule) &&
    /background:\s*var\(--canvas-deep\)/.test(mobileNavigationRule) &&
    /min-height:\s*100%/.test(mobileNavigationLinksRule) &&
    /height:\s*calc\(100dvh - 68px\)/.test(narrowMobileNavigationRule),
  'Mobile navigation must fill and scroll within the viewport below the header'
);
assert(
  /top:\s*13rem/.test(mobileHeroDecorationRule),
  'Mobile hero decoration must use a stable viewport position'
);
assert(
  /min-height:\s*calc\(clamp\(210px,\s*64vw,\s*250px\)\s*\*\s*2\.4\s*\+\s*12px\)/.test(
    narrowHeroStageRule
  ) &&
    /width:\s*clamp\(210px,\s*64vw,\s*250px\)/.test(
      narrowHeroPrimaryDeviceRule
    ),
  'Phone hero must reserve space for the bounded primary screenshot'
);
assert(
  /display:\s*block/.test(narrowDocumentTableRule) &&
    /width:\s*100%/.test(narrowDocumentTableRule) &&
    /min-width:\s*0/.test(narrowDocumentTableRule) &&
    /overflow-x:\s*auto/.test(narrowDocumentTableRule) &&
    /overscroll-behavior-inline:\s*contain/.test(narrowDocumentTableRule),
  'Narrow public-document tables must scroll without widening the page'
);
assert(
  notFoundSource.includes('class="not-found container"') &&
    notFoundSource.includes('class="button button--secondary"') &&
    !notFoundSource.includes('class="article-header container"') &&
    notFoundHtml.includes('id="not-found-title"'),
  '404 page must use the dedicated accessible not-found layout'
);
assert(
  /display:\s*grid/.test(notFoundRule) &&
    /min-height:\s*min\(720px,\s*100dvh\)/.test(notFoundRule) &&
    /padding-block:\s*calc\(76px\s*\+/.test(notFoundRule) &&
    /padding-top:\s*calc\(68px\s*\+\s*3rem\)/.test(narrowNotFoundRule),
  '404 page must remain clear of the fixed header at desktop and mobile widths'
);
assert(
  sourceCss.includes('height: auto') && !sourceCss.includes('aspect-ratio: 1179 / 2556'),
  'Device frame does not preserve the authentic screenshot aspect ratio'
);
assert(
  !sourceCss.includes('object-fit: cover'),
  'Design system must never crop authentic app screenshots with object-fit: cover'
);

const screenshotOrder = [
  ...index.matchAll(/data-screenshot-id="([^"]+)"/g)
].map((match) => match[1]);
const expectedScreenshotOrder = ['5', '2', '6', '5', 'table-ios', 'checklist-ios', '6', '2', '4', '7', '3', '4'];
assert(
  screenshotOrder.join(',') === expectedScreenshotOrder.join(','),
  `Screenshot order is ${screenshotOrder.join(',')}; expected the hero, sorted iOS carousel, then security screen`
);
assert(
  screenshotOrder.every((id) => screenshotCatalog.find((item) => item.id === id)?.platform === 'ios') &&
    screenshotCatalog.filter((item) => item.platform === 'ios').every((item) => screenshotOrder.includes(item.id)),
  'Homepage must show all iOS screenshots and no other platforms'
);
assert(
  (index.match(/<figcaption>/g) || []).length === expectedScreenshotOrder.length,
  'Homepage must render a visible caption for every displayed screenshot'
);

const screenshotImages = [
  ...index.matchAll(
    /<img[^>]+src="\/media\/screenshots\/[^"]+\.png"[^>]+alt="([^"]+)"/g
  )
].map((match) => match[1]);
assert(
  screenshotImages.length === expectedScreenshotOrder.length &&
    screenshotImages.every(
      (alt) => alt.length >= 30 && !/^screenshot\b/i.test(alt)
    ),
  'Every screenshot needs meaningful non-generic alt text'
);

for (const item of screenshotCatalog) {
  assert(await exists(`media/screenshots/${item.id}.png`), `Missing original screenshot ${item.id}.png`);
  for (const width of screenshotPreviewWidths(item)) {
    assert(await exists(`media/screenshots/${item.id}-${width}.webp`), `Missing optimized screenshot ${item.id}-${width}.webp`);
  }
}
assert(!index.includes('data-screenshot-id="1"') && !await exists('media/screenshots/1.png'), 'Sign-in screenshot must be removed');
assert(index.includes('data-screenshot-carousel') && index.includes('data-carousel-toggle'), 'Screenshot carousel and pause control are missing');
assert(!index.includes('data-feature-showcase'), 'Tables and checklists must share the screenshot carousel');

for (const asset of [
  'media/brand/logo.svg',
  'media/brand/app-mark.svg',
  'media/brand/app-icon-512.png',
  'media/brand/apple-touch-icon.png',
  'media/platforms/apple.svg',
  'media/platforms/android.svg',
  'media/platforms/github.svg',
  'media/platforms/windows.svg',
  'media/platforms/web-globe.svg',
  'media/store-badges/app-store.svg',
  'media/store-badges/google-play.png',
  'media/store-badges/microsoft-store.svg'
]) {
  assert(await exists(asset), `Missing prepared brand asset ${asset}`);
}

assert(
  storeActionsSource.includes('src="/media/brand/logo.svg"') &&
    !storeActionsSource.includes('/media/brand/app-mark.svg') &&
    !storeActionsSource.includes('/media/store-badges/'),
  'Store actions must use the transparent Better Keep mark and custom native buttons'
);

const storeBadgeMarkup = index.match(
  /<div class="store-badges">[\s\S]*?<\/div>/
)?.[0];
assert(
  storeBadgeMarkup &&
    !storeBadgeMarkup.includes('lucide-') &&
    !storeBadgeMarkup.includes('<img'),
  'Store actions must use inline native platform icons without badge images'
);
const storeActionIconTags = [
  ...(storeBadgeMarkup?.matchAll(
    /<svg\b[^>]*class="platform-icon"[^>]*data-platform-icon="([^"]+)"[^>]*>/g
  ) || [])
];
assert(
  JSON.stringify(storeActionIconTags.map((match) => match[1])) ===
    JSON.stringify(['apple', 'android', 'windows']) &&
    storeActionIconTags.every(
      ([tag]) =>
        tag.includes('aria-hidden="true"') &&
        tag.includes('focusable="false"')
    ),
  'Store actions must inline the three decorative native platform icons in order'
);
for (const copy of [
  'Download on the',
  'App Store',
  'Get it on',
  'Google Play',
  'Get it from',
  'Microsoft Store'
]) {
  assert(storeBadgeMarkup?.includes(copy), `Store action is missing “${copy}”`);
}
const actionFrameRule =
  sourceCss.match(/\.web-app-action,\s*\.store-badge\s*\{([^}]*)\}/)?.[1] || '';
for (const declaration of [
  /flex:\s*0 0 160px/,
  /width:\s*160px/,
  /height:\s*52px/,
  /padding:\s*4px/,
  /gap:\s*8px/,
  /box-sizing:\s*border-box/,
  /border-radius:\s*8px/
]) {
  assert(
    declaration.test(actionFrameRule),
    `Symmetric Web and store action frame is missing ${declaration}`
  );
}
const storeActionsRule =
  sourceCss.match(/\.store-actions\s*\{([^}]*)\}/)?.[1] || '';
for (const declaration of [
  /display:\s*flex/,
  /flex-wrap:\s*wrap/,
  /align-items:\s*center/,
  /gap:\s*8px/
]) {
  assert(
    declaration.test(storeActionsRule),
    `Store actions row is missing ${declaration}`
  );
}
const desktopSidebarActionsRule =
  sourceCss.match(
    /@media\s*\(min-width:\s*1121px\)[\s\S]*?\.article-action \.store-actions\s*\{([^}]*)\}/
  )?.[1] || '';
assert(
  /width:\s*100%/.test(desktopSidebarActionsRule) &&
    /max-width:\s*100%/.test(desktopSidebarActionsRule),
  'Desktop article sidebar actions must stay within the card content width'
);
const mobileStoreActionsRule =
  sourceCss.match(
    /@media\s*\(max-width:\s*680px\)[\s\S]*?\.store-actions\s*\{([^}]*)\}/
  )?.[1] || '';
assert(
  /width:\s*min\(328px, 100%\)/.test(mobileStoreActionsRule) &&
    /margin-inline:\s*auto/.test(mobileStoreActionsRule) &&
    /justify-content:\s*center/.test(mobileStoreActionsRule) &&
    !/(?:position|left|transform):/.test(mobileStoreActionsRule) &&
    sourceCss.includes('.article-action {\n  min-width: 0;') &&
    !sourceCss.includes('min-width: 320px'),
  'Narrow store actions must center and wrap inside their container without positional offsets'
);
const storeBadgeRule =
  [...sourceCss.matchAll(/(?:^|\n)\.store-badge\s*\{([^}]*)\}/g)]
    .map((match) => match[1])
    .find((rule) => /background:\s*#000/.test(rule)) || '';
assert(
  /overflow:\s*hidden/.test(storeBadgeRule) &&
    /border:\s*0/.test(storeBadgeRule) &&
    /background:\s*#000/.test(storeBadgeRule),
  'Store badge must expose a borderless black frame with a clipped outer radius'
);
const actionIconRule =
  sourceCss.match(/\.action-badge__icon\s*\{([^}]*)\}/)?.[1] || '';
const webActionIconRule =
  sourceCss.match(/\.action-badge__icon--web img\s*\{([^}]*)\}/)?.[1] || '';
const webActionRule =
  [...sourceCss.matchAll(/(?:^|\n)\.web-app-action\s*\{([^}]*)\}/g)]
    .map((match) => match[1])
    .find((rule) => /background:\s*#000/.test(rule)) || '';
assert(
  /width:\s*36px/.test(actionIconRule) &&
    /height:\s*36px/.test(actionIconRule) &&
    /flex:\s*0 0 36px/.test(actionIconRule) &&
    /place-items:\s*center/.test(actionIconRule) &&
    /filter:\s*none/.test(webActionIconRule) &&
    /transform:\s*scale\(1\.16\)/.test(webActionIconRule) &&
    /border:\s*0/.test(webActionRule) &&
    /background:\s*#000/.test(webActionRule) &&
    /color:\s*#fff/.test(webActionRule) &&
    !sourceCss.includes('.home-cta .web-app-action'),
  'Web and native actions must share a fixed visual scale with an inverted Web treatment'
);
assert(
  !sourceCss.includes('store-badge--') &&
    !storeActionsSource.includes('store-badge--') &&
    !sourceCss.includes('object-fit: cover'),
  'Store badges must not use platform-specific sizing overrides'
);
assert(
  (index.match(/class="store-badge"/g) || []).length === 6,
  'Homepage must render six store badges through the shared frame'
);
for (const platform of ['apple', 'google', 'microsoft']) {
  assert(
    (index.match(new RegExp(`data-store-platform="${platform}"`, 'g')) || [])
      .length === 2,
    `Homepage must render ${platform} once in each store-action group`
  );
}
assert(
  sourceCss.includes("html[data-store-platform='apple'] .store-badges") &&
    sourceCss.includes(".store-badge[data-store-platform='google']") &&
    sourceCss.includes(".store-badge[data-store-platform='microsoft']"),
  'Store badges must expose exactly the platform selected on the root element'
);
assert(
  /\.store-badges\s*\{[^}]*display:\s*none/s.test(sourceCss),
  'Native store badges must remain hidden before platform detection'
);
assert(
  !storeActionsSource.includes('includeMicrosoft'),
  'StoreActions must always render the Microsoft destination for detection'
);
assert(
  baseLayoutSource.includes('createStorePlatformBootstrap') &&
    index.indexOf('dataset.storePlatform') > -1 &&
    index.indexOf('dataset.storePlatform') < index.indexOf('</head>'),
  'Platform selection must execute synchronously before page content paints'
);
const platformMarkup = index.match(
  /<div class="platform-grid">[\s\S]*?<\/div>/
)?.[0];
const expectedPlatformIcons = ['apple', 'android', 'windows', 'web'];
const platformIconTags = [
  ...(platformMarkup?.matchAll(
    /<svg\b[^>]*class="platform-icon"[^>]*data-platform-icon="([^"]+)"[^>]*>/g
  ) || [])
];
const platformIcons = platformIconTags.map((match) => match[1]);
assert(
  JSON.stringify(platformIcons) === JSON.stringify(expectedPlatformIcons),
  'Platform cards must inline the four distinct local platform SVGs in order'
);
assert(
  platformMarkup &&
    !/<img\b|\/media\/(?:brand|platforms)\//.test(platformMarkup),
  'Platform cards must not fetch external or Better Keep app artwork'
);
assert(
  platformIconTags.every(
    ([tag]) =>
      tag.includes('aria-hidden="true"') &&
      tag.includes('focusable="false"')
  ),
  'Inline platform icons must remain decorative and unfocusable'
);

const publicDocumentRoutes = [
  'privacy.html',
  'terms.html',
  'pricing.html',
  'contact.html',
  'cancellation-refund.html',
  'delete-user.html'
];
const publicDocumentHtml = new Map();

for (const route of publicDocumentRoutes) {
  const html = await readFile(path.join(outputRoot, route), 'utf8');
  publicDocumentHtml.set(route, html);
  const body = html.match(
    /<div class="document-body"[\s\S]*?<\/article>/i
  )?.[0];
  assert(
    body,
    `${route} is not rendered through the shared public document design`
  );
  assert(
    body && !/\sstyle="/i.test(body),
    `${route} contains legacy inline presentation styles`
  );
  assert(
    body && !/href="[^"]*\.html(?:[?#"])/i.test(body),
    `${route} contains a legacy .html document link`
  );
  const documentSvgTags = body?.match(/<svg\b[^>]*>/g) || [];
  assert(
    documentSvgTags.every(
      (tag: string) =>
        tag.includes('aria-hidden="true"') &&
        tag.includes('focusable="false"')
    ),
    `${route} contains a non-decorative document icon`
  );
}

const classTokenCount = (html: string, token: string) =>
  [...html.matchAll(/class="([^"]+)"/g)].filter(([, classNames]) =>
    classNames.split(/\s+/).includes(token)
  ).length;
const expectedDocumentStructures = {
  'privacy.html': { 'content-section': 11 },
  'terms.html': { 'content-section': 18 },
  'pricing.html': {
    'comparison-table': 1,
    'why-card': 4,
    'free-feature': 8,
    'faq-item': 6
  },
  'contact.html': { 'contact-card': 3 },
  'cancellation-refund.html': {
    'policy-section': 4,
    'document-platform-card': 6,
    'contact-section': 1
  },
  'delete-user.html': {
    'content-section': 12,
    step: 12,
    'data-table': 3,
    'timeline-item': 4
  }
};

for (const [route, structures] of Object.entries(expectedDocumentStructures)) {
  const html = publicDocumentHtml.get(route) || '';
  for (const [className, expectedCount] of Object.entries(structures)) {
    assert(
      classTokenCount(html, className) === expectedCount,
      `${route} must render ${expectedCount} ${className} elements`
    );
  }
}

const refundHtml = publicDocumentHtml.get('cancellation-refund.html') || '';
const refundBody = refundHtml.match(
  /<div class="document-body"[\s\S]*?<\/article>/i
)?.[0];
assert(
  (refundBody?.match(/class="document-platform-card"/g) || []).length === 6,
  'Cancellation and refund policy must render six namespaced payment cards'
);
assert(
  refundBody && !refundBody.includes('class="platform-card"'),
  'Cancellation and refund policy must not reuse the homepage platform-card class'
);
const refundSvgTags = refundBody?.match(/<svg\b[^>]*>/g) || [];
assert(
  refundSvgTags.length > 0 &&
    refundSvgTags.every(
      (tag: string) =>
        tag.includes('aria-hidden="true"') &&
        tag.includes('focusable="false"')
    ),
  'Cancellation and refund policy SVGs must remain decorative and unfocusable'
);

const shareHtml = await readFile(path.join(outputRoot, 's', 'index.html'), 'utf8');
const shareScreens = [
  ...shareHtml.matchAll(/data-share-screen="([^"]+)"/g)
].map((match) => match[1]);
assert(
  JSON.stringify(shareScreens) ===
    JSON.stringify([
      'loading',
      'request',
      'pending',
      'content',
      'expired',
      'revoked',
      'denied',
      'notFound',
      'error'
    ]),
  'Shared-note viewer must render all nine explicit states in order'
);
assert(
  shareHtml.includes('<dialog class="share-lightbox"') &&
    shareHtml.includes('<form class="share-form"') &&
    shareHtml.includes('<label for="share-device-name">'),
  'Shared-note viewer is missing its accessible dialog or request form'
);
assert(
  shareHtml.includes('aria-live="polite"') &&
    shareHtml.includes('role="alert"'),
  'Shared-note viewer must announce pending and error states'
);
assert(
  !/\sonclick=|\sstyle=/i.test(shareHtml),
  'Shared-note viewer must not use inline handlers or presentation styles'
);
const shareSvgTags = shareHtml.match(/<svg\b[^>]*>/g) || [];
assert(
  shareSvgTags.length > 0 &&
    shareSvgTags.every(
      (tag: string) =>
        tag.includes('aria-hidden="true"') &&
        tag.includes('focusable="false"')
    ),
  'Shared-note viewer icons must remain decorative and unfocusable'
);
const shareCss = await readFile(
  path.join(siteRoot, 'src', 'styles', 'share-viewer.css'),
  'utf8'
);
assert(
  shareCss.includes('@media (prefers-reduced-motion: reduce)'),
  'Shared-note viewer must include a reduced-motion fallback'
);

const htmlFiles = await collectHtml(outputRoot);
for (const relativePath of htmlFiles) {
  const html = await readFile(path.join(outputRoot, relativePath), 'utf8');
  const text = visibleText(html);
  for (const removedCopy of removedMetaMarketingCopy) {
    assert(
      !text.includes(removedCopy),
      `${relativePath} contains removed meta-marketing copy: “${removedCopy}”`
    );
  }
  for (const match of html.matchAll(
    /<figure\b[^>]*data-screenshot-id="([^"]+)"[^>]*>[\s\S]*?<\/figure>/g
  )) {
    const [, screenshotId] = match;
    const figure = match[0];
    const expectedCaption = expectedScreenshotCaptions[screenshotId];
    const alt = figure.match(/<img\b[^>]*\balt="([^"]+)"/i)?.[1] || '';
    assert(
      figure.includes(expectedCaption),
      `${relativePath} screenshot ${screenshotId} is missing its configured capability caption`
    );
    assert(
      alt.length >= 30 && !/^screenshot\b/i.test(alt),
      `${relativePath} screenshot ${screenshotId} is missing meaningful alt text`
    );
  }
  const decorativeEmoji = [
    ...new Set(text.match(/\p{Extended_Pictographic}\uFE0F?/gu) || [])
  ];
  assert(
    decorativeEmoji.length === 0,
    `${relativePath} contains decorative emoji: ${decorativeEmoji.join(' ')}`
  );
  assert(
    !/(fontawesome|material-icons|unpkg\.com\/.*icon|cdn\.jsdelivr\.net\/.*icon)/i.test(
      html
    ),
    `${relativePath} depends on a runtime icon font or icon CDN`
  );
}

if (failures.length) {
  console.error('Design validation failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(
  `Design validation passed for ${htmlFiles.length} pages, six feature icons, and ${screenshotCatalog.length} screenshots.`
);
