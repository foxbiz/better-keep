type LegacyWorkerScope = {
  addEventListener: (type: 'install' | 'activate', listener: (event: {
    waitUntil: (task: Promise<void>) => void;
  }) => void) => void;
  skipWaiting: () => Promise<void>;
  registration: { unregister: () => Promise<boolean> };
  caches: Pick<CacheStorage, 'keys' | 'delete'>;
};

// Retire the former root PWA worker; the Flutter app owns its worker under /app/.
export function retireLegacyWorker(self: LegacyWorkerScope) {
  self.addEventListener('install', () => { void self.skipWaiting(); });
  self.addEventListener('activate', (event) => {
    event.waitUntil((async () => {
      const legacyCaches = new Set([
        'flutter-app-cache', 'flutter-temp-cache', 'flutter-app-manifest'
      ]);
      const cacheNames = await self.caches.keys();
      await Promise.all(cacheNames
        .filter((name) => legacyCaches.has(name))
        .map((name) => self.caches.delete(name)));
      await self.registration.unregister();
    })());
  });
}

export function createLegacyWorkerScript() {
  return `(${retireLegacyWorker.toString()})(self);`;
}
