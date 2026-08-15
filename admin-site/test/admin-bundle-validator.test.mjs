import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const validator = fileURLToPath(
  new URL('../../scripts/validate_admin_bundle.mjs', import.meta.url)
);

async function createBundle(appCheckMeta) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'better-keep-admin-validator-'));
  await mkdir(path.join(root, '_astro'));
  await Promise.all([
    writeFile(
      path.join(root, 'index.html'),
      `<!doctype html>
      <html>
        <head>
          <meta name="robots" content="noindex, nofollow, noarchive">
          ${appCheckMeta}
          <link rel="stylesheet" href="/_astro/admin.css">
        </head>
        <body>
          <main>Private operations</main>
          <button data-login-button disabled>Sign in</button>
          <script src="/_astro/admin.js"></script>
        </body>
      </html>`
    ),
    writeFile(path.join(root, '_astro', 'admin.css'), 'body { color: white; }'),
    writeFile(path.join(root, '_astro', 'admin.js'), 'globalThis.admin = true;')
  ]);
  return root;
}

function validate(root) {
  return spawnSync(process.execPath, [validator, root], { encoding: 'utf8' });
}

test('admin bundle validator accepts a configured App Check key', async (t) => {
  const root = await createBundle(
    '<meta name="admin-app-check-site-key" content="configured-public-site-key">'
  );
  t.after(() => rm(root, { recursive: true, force: true }));

  const result = validate(root);

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Admin bundle validation passed/);
});

for (const [article, label, appCheckMeta] of [
  ['a', 'missing', ''],
  ['an', 'empty', '<meta name="admin-app-check-site-key" content="">']
]) {
  test(`admin bundle validator rejects ${article} ${label} App Check key`, async (t) => {
    const root = await createBundle(appCheckMeta);
    t.after(() => rm(root, { recursive: true, force: true }));

    const result = validate(root);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /App Check site key must be present and non-empty/);
  });
}
