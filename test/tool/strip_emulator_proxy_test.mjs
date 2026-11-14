import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import test from 'node:test';

test('release packaging removes emulator bridges but preserves OAuth callback assets', async () => {
  const root = await mkdtemp(join(tmpdir(), 'better-keep-hosting-'));
  try {
    await mkdir(join(root, 'app/js'), { recursive: true });
    await mkdir(join(root, 'js'));
    await writeFile(join(root, 'app/index.html'), await readFile('web/index.html'));
    for (const path of ['app/js/firebase_emulator_proxy.js', 'js/firebase_emulator_proxy.js', 'app/storage-auth.html']) {
      await writeFile(join(root, path), 'fixture');
    }
    for (let i = 0; i < 2; i++) execFileSync(process.execPath, [resolve('scripts/strip_emulator_proxy.mjs'), root]);
    const html = await readFile(join(root, 'app/index.html'), 'utf8');
    assert.ok(!html.includes('firebase_emulator_proxy.js'));
    assert.ok(html.includes('flutter_bootstrap.js'));
    await assert.rejects(access(join(root, 'app/js/firebase_emulator_proxy.js')));
    await assert.rejects(access(join(root, 'js/firebase_emulator_proxy.js')));
    assert.equal(await readFile(join(root, 'app/storage-auth.html'), 'utf8'), 'fixture');
  } finally { await rm(root, { recursive: true, force: true }); }
});

 test('packaging fails closed when the emulator script markup changes', async () => {
 const root = await mkdtemp(join(tmpdir(), 'better-keep-hosting-'));
 try {
 await mkdir(join(root, 'app'), {recursive:true});
 await writeFile(join(root, 'app/index.html'), '<script defer src="js/firebase_emulator_proxy.js"></script>');
 assert.throws(() => execFileSync(process.execPath, [resolve('scripts/strip_emulator_proxy.mjs'),root], {stdio:'pipe'}));
 } finally { await rm(root, {recursive:true,force:true}); }
 });
