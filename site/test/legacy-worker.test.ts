import assert from 'node:assert/strict';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import { createLegacyWorkerScript } from '../src/lib/legacy-worker.ts';

test('the emitted legacy worker retires only the former root app caches', async () => {
  type WorkerEvent = { waitUntil: (task: Promise<void>) => void };
  const listeners = new Map<string, (event: WorkerEvent) => void>();
  const removed: string[] = [];
  let skipped = false;
  let unregistered = false;
  const worker = {
    addEventListener: (name: string, callback: (event: WorkerEvent) => void) => listeners.set(name, callback),
    skipWaiting: async () => { skipped = true; },
    registration: { unregister: async () => { unregistered = true; return true; } },
    caches: {
      keys: async () => ['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest', 'new-app-cache'],
      delete: async (name: string) => { removed.push(name); return true; }
    }
  };
  // Execute the actual emitted script to catch type syntax leaking into browser code.
  runInNewContext(createLegacyWorkerScript(), { self: worker });
  const tasks: Promise<void>[] = [];
  const event = { waitUntil: (task: Promise<void>) => { tasks.push(task); } };
  listeners.get('install')!(event);
  listeners.get('activate')!(event);
  await Promise.all(tasks);
  assert.equal(skipped, true);
  assert.equal(unregistered, true);
  assert.deepEqual(removed, ['flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest']);
});
