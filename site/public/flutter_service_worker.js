// Retires the legacy Flutter PWA service worker that previously controlled `/`.
// The current Flutter app registers its own worker below `/app/`.
self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const legacyCaches = new Set([
        'flutter-app-cache',
        'flutter-temp-cache',
        'flutter-app-manifest'
      ]);
      const cacheNames = await caches.keys();
      await Promise.all(
        cacheNames
          .filter((cacheName) => legacyCaches.has(cacheName))
          .map((cacheName) => caches.delete(cacheName))
      );
      await self.registration.unregister();
    })()
  );
});
