import assert from 'node:assert/strict';
import {mkdtemp, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
const script = resolve('scripts/validate_web_compatibility.mjs');
test('web release rejects missing/malformed effective compatibility defines without printing secrets', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'web-compatibility-'));
  try {
    const env = join(dir, '.env');
    const key = 'ab'.repeat(32);
    await writeFile(env, `WEB_STORAGE_KEY=${key}\n`);
    const run = (...args) => spawnSync(process.execPath, [script, ...args], {encoding:'utf8'});
    assert.equal(run().status, 1);
    assert.equal(run(`--dart-define-from-file=${env}`).status, 0);
    const rejected = run(`--dart-define-from-file=${env}`, '--dart-define=WEB_STORAGE_KEY=private-malformed-value');
    assert.equal(rejected.status, 1);
    assert.equal(run('--dart-define=WEB_STORAGE_KEY=bad', `--dart-define-from-file=${env}`).status, 1);
    assert.equal(run('--dart-define=WEB_STORAGE_KEY=' + key, `--dart-define-from-file=${env}`).status, 0);
    assert.ok(!rejected.stderr.includes('private-malformed-value'));
    assert.ok(!rejected.stderr.includes(key));
    const json = join(dir, 'defines.json');
    await writeFile(json, JSON.stringify({WEB_STORAGE_KEY:key}));
    assert.equal(run('--dart-define-from-file', json).status, 0);
  } finally { await rm(dir, {recursive:true, force:true}); }
});
