import assert from 'node:assert/strict';
import test from 'node:test';

test('emulator forwarding is enabled only with a configured HTTPS origin', async () => {
  const previous = process.env.EMULATOR_WEB_ORIGIN;
  try {
    process.env.EMULATOR_WEB_ORIGIN = '';
    const disabled = (await import(new URL('../astro.config.ts?emulator-disabled', import.meta.url).href)).default;
    assert.equal(Object.keys(disabled.vite.server.proxy).some((key) => key.includes('__emulator')), false);
    process.env.EMULATOR_WEB_ORIGIN = 'https://dev.example.test';
    const enabled = (await import(new URL('../astro.config.ts?emulator-enabled', import.meta.url).href)).default;
    for (const [service, port] of Object.entries({auth: 9099, firestore: 8080, functions: 5001, storage: 9199})) {
      const routes = Object.entries(enabled.vite.server.proxy);
      const url = `/__emulator/${service}/v1/test?value=abc%2Fdef`;
      const match = routes.find(([pattern]) => pattern.startsWith('^') && new RegExp(pattern).test(url));
      assert.ok(match);
      const proxy = match[1] as {
        target: string;
        rewrite: (path: string) => string;
        configure: (server: unknown) => void;
      };
      assert.equal(proxy.target, `http://127.0.0.1:${port}`);
      assert.equal(proxy.rewrite(url), '/v1/test?value=abc%2Fdef');
      assert.equal(new RegExp(match[0]).test(`/__emulator/${service}-other/v1/test`), false);
      const headers: Record<string, string> = {
        'x-goog-upload-url': `http://127.0.0.1:${port}/v0/upload?upload_id=test`,
        location: 'https://example.test/unrelated',
      };
      proxy.configure({on(event: string, handler: (response: {headers: typeof headers}) => void) {
        assert.equal(event, 'proxyRes');
        handler({headers});
      }});
      assert.equal(headers['x-goog-upload-url'], `/__emulator/${service}/v0/upload?upload_id=test`);
      assert.equal(headers.location, 'https://example.test/unrelated');
    }
  } finally {
    if (previous === undefined) delete process.env.EMULATOR_WEB_ORIGIN;
    else process.env.EMULATOR_WEB_ORIGIN = previous;
  }
});
