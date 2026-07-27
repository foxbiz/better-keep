import { readFile, readdir, access } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const projectRoot = path.resolve(import.meta.dirname, '..');
const metadataRoot = path.join(projectRoot, 'store', 'metadata');
const failures = [];
const prohibitedStoreClaims = [
  /\bgoogle(?:\s+keep)?\b/i,
  /\blinux\b/i,
  /\bOSS\b/i,
  /\bopen[- ]source\b/i,
  /\bindependent(?:ly)? audited\b/i
];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

function length(value) {
  return [...value].length;
}

const facts = JSON.parse(
  await readFile(
    path.join(projectRoot, 'site', 'src', 'data', 'product-facts.json'),
    'utf8'
  )
);
const files = (await readdir(metadataRoot))
  .filter((file) => file.endsWith('.json'))
  .sort();
const locales = [];

for (const file of files) {
  const metadata = JSON.parse(
    await readFile(path.join(metadataRoot, file), 'utf8')
  );
  const label = metadata.locale || file;
  locales.push(label);

  assert(file === `${label}.json`, `${file}: locale and filename differ`);
  assert(
    ['ready', 'needs-native-review'].includes(metadata.reviewStatus),
    `${label}: invalid reviewStatus`
  );
  assert(length(metadata.appStore.name) <= 30, `${label}: Apple name exceeds 30`);
  assert(
    length(metadata.appStore.subtitle) <= 30,
    `${label}: Apple subtitle exceeds 30`
  );
  assert(
    length(metadata.appStore.keywords) <= 100,
    `${label}: Apple keyword field exceeds 100`
  );
  assert(length(metadata.playStore.title) <= 30, `${label}: Play title exceeds 30`);
  assert(
    length(metadata.playStore.shortDescription) <= 80,
    `${label}: Play short description exceeds 80`
  );
  assert(
    length(metadata.playStore.fullDescription) <= 4000,
    `${label}: Play full description exceeds 4,000`
  );
  assert(
    metadata.screenshotCopy?.length === 8,
    `${label}: exactly eight screenshot messages are required`
  );

  const keywords = metadata.appStore.keywords
    .split(',')
    .map((keyword) => keyword.trim().toLocaleLowerCase(label))
    .filter(Boolean);
  assert(
    keywords.length === new Set(keywords).size,
    `${label}: duplicate Apple keywords`
  );

  const allStoreCopy = [
    ...Object.values(metadata.appStore),
    ...Object.values(metadata.playStore),
    ...metadata.screenshotCopy
  ].join('\n');
  for (const prohibited of prohibitedStoreClaims) {
    assert(
      !prohibited.test(allStoreCopy),
      `${label}: prohibited or unverified store wording matches ${prohibited}`
    );
  }
}

const english = JSON.parse(
  await readFile(path.join(metadataRoot, 'en-US.json'), 'utf8')
);
assert(english.appStore.name === facts.storeName, 'English store name drifted');
assert(
  english.appStore.subtitle === facts.appleSubtitle,
  'English Apple subtitle drifted'
);
assert(
  english.appStore.keywords === facts.appleKeywords,
  'English Apple keywords drifted'
);
assert(
  english.playStore.title === facts.storeName,
  'English Play title drifted'
);
assert(
  english.playStore.shortDescription === facts.shortDescription,
  'English Play short description drifted'
);
assert(
  JSON.stringify(facts.platforms) ===
    JSON.stringify(['Android', 'iOS', 'macOS', 'Windows', 'Web']),
  'Supported platforms drifted'
);
assert(
  facts.encryption.independentlyAudited === false,
  'Audit status must be explicitly false until a report is published'
);

const screenshotPlan = JSON.parse(
  await readFile(
    path.join(projectRoot, 'store', 'creative', 'screenshot-plan.json'),
    'utf8'
  )
);
assert(screenshotPlan.frames.length === 8, 'Creative plan must contain eight frames');
for (const frame of screenshotPlan.frames) {
  if (!frame.source) continue;
  try {
    await access(path.join(projectRoot, frame.source));
  } catch {
    failures.push(`Creative frame ${frame.position} references missing ${frame.source}`);
  }
}

assert(
  JSON.stringify(locales) ===
    JSON.stringify(['en-US', 'id-ID', 'ja-JP', 'ko-KR', 'pt-BR', 'zh-CN']),
  'Required store locales are incomplete or an unapproved locale was added'
);

if (failures.length) {
  console.error('Store metadata validation failed:');
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(`Store metadata validation passed for ${files.length} locales.`);
