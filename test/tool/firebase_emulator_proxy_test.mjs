import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync('web/js/firebase_emulator_proxy.js', 'utf8');
function setup() {
  const calls = [];
  class Xhr { open(...args) { calls.push(args); } }
  const window = { fetch: (...args) => { calls.push(args); return Promise.resolve(); } };
  vm.runInNewContext(source, { window, XMLHttpRequest: Xhr, URL, Request, location: { href: 'https://dev.example.test/app' } });
  return { window, Xhr, calls };
}

test('only exact configured emulator endpoints are forwarded over HTTPS', async () => {
  const { window, calls } = setup();
  window.betterKeepConfigureEmulatorProxy('192.168.1.25', 'https://dev.example.test');
  for (const [port, service] of [[9099, 'auth'], [8080, 'firestore'], [5001, 'functions'], [9199, 'storage']]) {
    await window.fetch(`http://192.168.1.25:${port}/some/path?value=abc%2Fdef`);
    assert.equal(calls.at(-1)[0], `https://dev.example.test/__emulator/${service}/some/path?value=abc%2Fdef`);
  }
  for (const url of ['https://api.dropboxapi.com/oauth2/token', 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword', 'http://192.168.1.25:9999/test', 'http://other.test:9099/test']) {
    await window.fetch(url);
    assert.equal(calls.at(-1)[0], url);
  }
});

test('fetch preserves request body, headers and explicit options', async () => {
  const { window, calls } = setup();
  window.betterKeepConfigureEmulatorProxy('localhost', 'https://dev.example.test');
  const request = new Request('http://localhost:9099/test', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"test":true}' });
  const options = { credentials: 'omit' };
  await window.fetch(request, options);
  const [forwarded, init] = calls[0];
  assert.equal(forwarded.url, 'https://dev.example.test/__emulator/auth/test');
  assert.equal(forwarded.method, 'POST');
  assert.equal(forwarded.headers.get('Content-Type'), 'application/json');
  assert.equal(await forwarded.text(), '{"test":true}');
  assert.equal(init, options);
});

test('Firestore and Storage XHR preserve open arguments and can change host', () => {
  const { window, Xhr, calls } = setup();
  window.betterKeepConfigureEmulatorProxy('localhost', 'https://dev.example.test');
  new Xhr().open('POST', 'http://localhost:8080/channel?SID=test', true);
  assert.deepEqual(calls[0], ['POST', 'https://dev.example.test/__emulator/firestore/channel?SID=test', true]);
  window.betterKeepConfigureEmulatorProxy('127.0.0.1', 'https://other.example.test');
  new Xhr().open('GET', 'http://localhost:9199/v0/b/test', false);
  assert.equal(calls[1][1], 'http://localhost:9199/v0/b/test');
  new Xhr().open('GET', 'http://127.0.0.1:9199/v0/b/test', true);
  assert.equal(calls[2][1], 'https://other.example.test/__emulator/storage/v0/b/test');
});

test('rejects insecure or credential-bearing proxy destinations before installation', () => {
  const { window } = setup();
  const original = window.fetch;
  for (const origin of ['http://dev.example.test', 'https://user:password@dev.example.test', 'https://dev.example.test/path', 'https://dev.example.test?key=test']) {
    assert.throws(() => window.betterKeepConfigureEmulatorProxy('localhost', origin));
    assert.equal(window.fetch, original);
  }
});
