import type { APIRoute } from 'astro';
import { createLegacyWorkerScript } from '../lib/legacy-worker.ts';

export const GET: APIRoute = () => new Response(createLegacyWorkerScript(), {
  headers: { 'Content-Type': 'application/javascript; charset=utf-8' }
});
