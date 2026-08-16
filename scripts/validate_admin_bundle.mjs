import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(process.argv[2] || 'build/admin');
const failures = [];

async function exists(relativePath) {
  try {
    await access(path.join(root, relativePath));
    return true;
  } catch {
    return false;
  }
}

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function filesUnder(directory = root) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const absolute = path.join(directory, entry.name);
    return entry.isDirectory() ? filesUnder(absolute) : [absolute];
  }));
  return nested.flat();
}

assert(await exists('index.html'), 'Admin Hosting is missing index.html');
const indexHtml = await readFile(path.join(root, 'index.html'), 'utf8').catch(() => '');
const files = await filesUnder();
const text = (
  await Promise.all(
    files
      .filter((file) => /\.(?:html|js|css|json|txt)$/i.test(file))
      .map((file) => readFile(file, 'utf8'))
  )
).join('\n');

assert(text.includes('Private operations'), 'Admin login content is missing');
assert(text.includes('noindex, nofollow, noarchive'), 'Admin HTML must be noindex');
const appCheckMeta = (indexHtml.match(/<meta\b[^>]*>/gi) ?? []).find((tag) =>
  /\bname\s*=\s*(["'])admin-app-check-site-key\1/i.test(tag)
);
const appCheckContent = appCheckMeta?.match(/\bcontent\s*=\s*(["'])(.*?)\1/i)?.[2].trim();
if (process.env.GITHUB_ACTIONS !== 'true') {
  assert(Boolean(appCheckContent), 'Admin App Check site key must be present and non-empty');
}
assert(!text.includes('plausible.io'), 'Admin bundle must not include analytics');
assert(!/dellevenjack/i.test(text), 'Admin bundle contains the former personal identifier');
assert(!/browserLocalPersistence/.test(text), 'Admin bundle must not persist sessions locally');
assert(!/name=["'](?:email|password)["']/i.test(text), 'Credentials must not be serializable by form submission');
assert(/data-login-button[^>]*disabled|disabled[^>]*data-login-button/i.test(text), 'Admin login must fail closed');
assert(files.some((file) => /\/_astro\/.*\.css$/.test(file)), 'Admin styles must be external');
assert(files.some((file) => /\/_astro\/.*\.js$/.test(file)), 'Admin scripts must be external');

if (failures.length > 0) {
  console.error('Admin bundle validation failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Admin bundle validation passed.');
}
