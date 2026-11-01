import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { storageCallback } from '../scripts/storage_callback.ts';
const previousOrigin = process.env.EMULATOR_WEB_ORIGIN;
process.env.EMULATOR_WEB_ORIGIN = 'https://dev.example.test';
const { default: config } = await import('../astro.config.ts');
if (previousOrigin === undefined) delete process.env.EMULATOR_WEB_ORIGIN;
else process.env.EMULATOR_WEB_ORIGIN = previousOrigin;

test('Flutter debug requests preserve the development HTTPS origin', () => {
  assert.ok(config.server && typeof config.server !== 'function');
  assert.deepEqual(config.server.allowedHosts, ['dev.example.test']);
  const proxy = config.vite!.server!.proxy!['^/app(?:/|\\?|$)'];
  assert.equal(typeof proxy, 'object');
  let forward: (request: { path: string }, incoming: { headers: { host: string } }) => void;
  (proxy as { configure: (server: unknown) => void }).configure({
    on(event: string, listener: typeof forward) {
      assert.equal(event, 'proxyReq');
      forward = listener;
    },
  });
  const request = { path: '/app/main_module.bootstrap.js' };
  forward!(request, { headers: { host: 'dev.example.test' } });
  assert.equal(request.path, 'https://dev.example.test/app/main_module.bootstrap.js');
  const local = { path: '/app/main_module.bootstrap.js' };
  forward!(local, { headers: { host: 'localhost:4321' } });
  assert.equal(local.path, '/app/main_module.bootstrap.js');
});

test('development callbacks serve the production relay without a Flutter upstream', async () => {
  const expected = await readFile(new URL('../../web/storage-auth.html', import.meta.url));
  for (const suffix of ['', '?state=app.test&code=synthetic', '/?error=access_denied']) {
    const headers = new Map<string, string>();
    let body: Buffer | undefined;
    const response = {
      statusCode: 0,
      setHeader: (name: string, value: string) => headers.set(name, value),
      end: (value?: Buffer) => { body = value; },
    };
    await storageCallback(
      {url: `/oauth/storage/callback${suffix}`, method: 'GET'} as IncomingMessage,
      response as unknown as ServerResponse,
      () => assert.fail('Callback must not reach the legacy proxy'),
    );
    assert.equal(response.statusCode, 200);
    assert.deepEqual(body, expected);
    assert.equal(headers.get('Cache-Control'), 'no-store');
    assert.equal(headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(headers.get('Content-Type'), 'text/html; charset=utf-8');
  }
});

test('callback middleware only handles the exact route and safe methods', async () => {
  for (const path of ['/app', '/oauth/storage/start', '/oauth/storage/callback-extra', '/oauth/storage/callback/extra']) {
    let forwarded = false;
    await storageCallback({url: path, method: 'GET'} as IncomingMessage,
      {setHeader: () => assert.fail('Unrelated response changed')} as unknown as ServerResponse,
      () => { forwarded = true; });
    assert.equal(forwarded, true);
  }
  for (const method of ['HEAD', 'POST']) {
    let body: unknown = 'not ended';
    const response = {statusCode: 0, setHeader() {}, end(value: unknown) { body = value; }};
    await storageCallback({url: '/oauth/storage/callback', method} as IncomingMessage,
      response as unknown as ServerResponse, () => assert.fail('Unexpected fallback'));
    assert.equal(response.statusCode, method === 'HEAD' ? 200 : 405);
    assert.equal(body, undefined);
  }
});

test('hosting serves the registered callback without a server token exchange', async () => {
  for (const file of ['firebase.deploy.json', 'firebase.emulators.json']) {
    const config = JSON.parse(await readFile(`../${file}`, 'utf8'));
    const sites = Array.isArray(config.hosting) ? config.hosting : [config.hosting];
    const callback = sites.flatMap((site: { rewrites?: unknown[] }) => site.rewrites ?? []).find(
      (route: { source: string }) => route.source === '/oauth/storage/callback',
    );
    assert.deepEqual(callback, {
      source: '/oauth/storage/callback',
      destination: '/app/storage-auth.html',
    });
  }
});
