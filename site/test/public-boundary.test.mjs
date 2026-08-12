import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

async function sourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  return (await Promise.all(entries.map(async (entry) => {
    const absolute = path.join(directory, entry.name);
    return entry.isDirectory() ? sourceFiles(absolute) : [absolute];
  }))).flat();
}

test('the public site source cannot emit the administrator portal', async () => {
  await assert.rejects(() => access('src/pages/admin.astro'));
  const files = await sourceFiles('src');
  const source = (
    await Promise.all(
      files
        .filter((file) => /\.(?:astro|js|mjs|ts|css)$/i.test(file))
        .map((file) => readFile(file, 'utf8'))
    )
  ).join('\n');
  assert.doesNotMatch(source, /data-admin-root|Private operations|browserSessionPersistence/);
});
