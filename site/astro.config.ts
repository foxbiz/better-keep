import { defineConfig } from 'astro/config';
import { fileURLToPath } from 'node:url';
import { loadEnv } from 'vite';
import { storageCallback } from './scripts/storage_callback.ts';

const flutterDevOrigin = process.env.BETTER_KEEP_FLUTTER_DEV_ORIGIN ?? 'http://127.0.0.1:63630';
// A configured HTTPS emulator origin also enables its local development proxy.
const developmentEnv = loadEnv('development', fileURLToPath(new URL('../', import.meta.url)), 'EMULATOR_WEB_ORIGIN');
const configuredOrigin = process.env.EMULATOR_WEB_ORIGIN ?? developmentEnv.EMULATOR_WEB_ORIGIN;
const developmentOrigin = configuredOrigin ? new URL(configuredOrigin) : undefined;
if (developmentOrigin && (developmentOrigin.protocol !== 'https:' ||
    developmentOrigin.username || developmentOrigin.password ||
    developmentOrigin.pathname !== '/' || developmentOrigin.search || developmentOrigin.hash)) {
  throw new Error('EMULATOR_WEB_ORIGIN must be an HTTPS origin without a path or credentials.');
}
const emulatorProxies = developmentOrigin
  ? Object.fromEntries(Object.entries({ auth: 9099, firestore: 8080, functions: 5001, storage: 9199 })
      .map(([service, port]) => [`^/__emulator/${service}(?:/|\\?|$)`, {
        target: `http://127.0.0.1:${port}`,
        changeOrigin: true,
        rewrite: (path: string) => path.replace(`/__emulator/${service}`, ''),
        configure(proxy: { on: (event: string, handler: (response: { headers: Record<string, string | string[] | undefined> }) => void) => void }) {
          proxy.on('proxyRes', (response) => {
            response.headers['cache-control'] = 'no-store';
            response.headers['x-accel-buffering'] = 'no';
            // Storage resumable uploads must keep subsequent requests on the
            // same HTTPS proxy instead of returning the local upstream URL.
            for (const header of ['location', 'x-goog-upload-url']) {
              const value = response.headers[header];
              if (typeof value !== 'string') continue;
              const url = new URL(value, `http://127.0.0.1:${port}`);
              if (url.origin === `http://127.0.0.1:${port}`) {
                response.headers[header] = `/__emulator/${service}${url.pathname}${url.search}`;
              }
            }
          });
        },
      }]))
  : {};

export default defineConfig({
  site: 'https://betterkeep.app',
  output: 'static',
  trailingSlash: 'never',
  server: {
    allowedHosts: developmentOrigin ? [developmentOrigin.hostname] : []
  },
  vite: {
    plugins: [{
      name: 'storage-oauth-callback',
      apply: 'serve',
      configureServer(server) {
        // Runs before proxies: mobile callbacks do not depend on Flutter web.
        server.middlewares.use(storageCallback);
      },
    }],
    server: {
      proxy: {
        ...emulatorProxies,
        '^/app(?:/|\\?|$)': {
          // Keep browser OAuth and Flutter assets on the public HTTPS origin.
          // Override only the local upstream when running an isolated test app.
          target: flutterDevOrigin,
          changeOrigin: true,
          ws: true,
          configure(proxy) {
            proxy.on('proxyReq', (request, incoming) => {
              if (developmentOrigin && incoming.headers.host === developmentOrigin.host) {
                // DWDS derives its debug URL from the request target. Preserve
                // the public origin instead of emitting the local upstream URL.
                request.path = `${developmentOrigin.origin}${request.path}`;
              }
            });
          },
        },
        '/oauth/storage': {
          target: 'http://127.0.0.1:5002',
          changeOrigin: true,
          configure(proxy) {
            proxy.on('proxyReq', (request) => {
              // OAuth uses HTTP redirects, not WebSocket upgrades. Firebase's
              // Hosting proxy rejects upgrade headers forwarded by some tunnels.
              request.setHeader('connection', 'close');
              request.removeHeader('upgrade');
            });
          }
        }
      }
    }
  },
  build: {
    format: 'file'
  }
});
