import { readFile } from 'node:fs/promises';
import type { Connect } from 'vite';

// Native OAuth must work without a running Flutter web development server.
// Serve the same relay as production Hosting; grants are processed only by the client.
export const storageCallback: Connect.NextHandleFunction = async (request, response, next) => {
  const path = request.url?.split('?')[0];
  if (path !== '/oauth/storage/callback' && path !== '/oauth/storage/callback/') {
    next();
    return;
  }
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.statusCode = 405;
    response.setHeader('Allow', 'GET, HEAD');
    response.end();
    return;
  }
  try {
    const page = await readFile(new URL('../../web/storage-auth.html', import.meta.url));
    response.statusCode = 200;
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end(request.method === 'HEAD' ? undefined : page);
  } catch {
    response.statusCode = 503;
    response.setHeader('Content-Type', 'text/plain; charset=utf-8');
    response.end(request.method === 'HEAD' ? undefined :
      'Unable to open the connection page. Return to Better Keep and try again.');
  }
};
