import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const siteRoot = path.resolve(import.meta.dirname, '..');
const outputRoot = path.join(siteRoot, 'dist');
const failures = [];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function exists(relativePath) {
  try {
    await access(path.join(outputRoot, relativePath));
    return true;
  } catch {
    return false;
  }
}

async function collectHtml(directory, prefix = '') {
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

function visibleText(html) {
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
const expectedFeatureIcons = [
  'text-cursor-input',
  'shield-check',
  'cloud-off',
  'monitor-smartphone',
  'folders',
  'audio-waveform'
];

assert(
  (index.match(/class="feature-card"/g) || []).length === 6,
  'Homepage must render exactly six primary feature cards'
);

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

const screenshotOrder = [
  ...index.matchAll(/<img[^>]+src="\/media\/screenshots\/([1-7])\.png"/g)
].map((match) => match[1]);
assert(
  screenshotOrder.join(',') === '2,5,6,4,7,3,1',
  `Screenshot order is ${screenshotOrder.join(',')}; expected 2,5,6,4,7,3,1`
);
assert(
  (index.match(/<figcaption>/g) || []).length === 7,
  'Homepage must render a visible caption for all seven screenshots'
);

const screenshotImages = [
  ...index.matchAll(
    /<img[^>]+src="\/media\/screenshots\/[1-7]\.png"[^>]+alt="([^"]+)"/g
  )
].map((match) => match[1]);
assert(
  screenshotImages.length === 7 &&
    screenshotImages.every(
      (alt) => alt.length >= 30 && !/^screenshot\b/i.test(alt)
    ),
  'Every screenshot needs meaningful non-generic alt text'
);

for (const id of ['1', '2', '3', '4', '5', '6', '7']) {
  assert(
    await exists(`media/screenshots/${id}.png`),
    `Missing original screenshot ${id}.png`
  );
  assert(
    await exists(`media/screenshots/${id}-480.webp`),
    `Missing optimized screenshot ${id}-480.webp`
  );
}

for (const route of [
  'privacy.html',
  'terms.html',
  'pricing.html',
  'contact.html',
  'cancellation-refund.html',
  'delete-user.html'
]) {
  const html = await readFile(path.join(outputRoot, route), 'utf8');
  assert(
    html.includes('class="document-body"'),
    `${route} is not rendered through the shared public document design`
  );
  assert(
    !/\sstyle="/i.test(
      html.match(/<div class="document-body"[\s\S]*?<\/article>/i)?.[0] || ''
    ),
    `${route} contains legacy inline presentation styles`
  );
}

const htmlFiles = await collectHtml(outputRoot);
for (const relativePath of htmlFiles) {
  const html = await readFile(path.join(outputRoot, relativePath), 'utf8');
  const text = visibleText(html);
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
  `Design validation passed for ${htmlFiles.length} pages, six feature icons, and seven screenshots.`
);
