// Cache only public app resources. Account, provider and OAuth traffic bypass this worker.
const scope = new URL(self.registration.scope);
const app = new URL(scope.pathname.replace(/\/?$/, "/"), scope.origin);
const runtime = new URL("./", self.location.href);
const bundledAssets = [];
const cacheName = "better-keep-offline-app-v1";
const bootstrap = new URL("flutter_bootstrap.js", runtime);
const entry = new URL("index.html", app);
const channelFiles = ["beta-launcher.js", "beta-release.json"];
const shellFiles = [
	"js/app_install.js",
	"js/razorpay_checkout.js",
	"js/firebase_emulator_proxy.js",
	"icons/logo.svg",
	"manifest.json",
];

function publicResource(url) {
	if (url.search || url.hash) return false;
	if (url.origin === "https://www.gstatic.com")
		return /^\/firebasejs\/[\d.]+\/[\w.-]+\.js$/.test(url.pathname);
	if (url.origin === "https://fonts.gstatic.com")
		return /^\/s\/[\w/-]+\/[\w.-]+\.(?:woff2?|ttf)$/.test(url.pathname);
	if (url.origin !== app.origin || !url.pathname.startsWith(app.pathname))
		return false;
	const path = url.pathname.slice(app.pathname.length);
	if (channelFiles.includes(path) || shellFiles.includes(path)) return true;
	const name = path.replace(/^releases\/[a-z0-9-]+\/(?:stable\/)?/, "");
	return (
		/^(?:assets|canvaskit|icons|vendor)\//.test(name) ||
		/^(?:main\.dart\.(?:js|wasm|mjs)|flutter(?:_bootstrap)?\.js|version\.json|(?:beta-runtime\/v1\/)?(?:sqflite_sw\.js|sqlite3\.wasm))$/.test(
			name,
		)
	);
}

self.addEventListener("install", (event) => {
	event.waitUntil(
		(async () => {
			const cache = await caches.open(cacheName);
			const html = await fetch(app.href, { cache: "reload" });
			if (!html.ok || !html.headers.get("content-type")?.includes("text/html"))
				throw new Error("App document unavailable");
			// Hosting may redirect /app/ or index.html. A cached navigation response
			// must also work when the browser disallows following redirects offline.
			const document = await html.text();
			const headers = new Headers(html.headers);
			headers.delete("content-length");
			headers.delete("content-encoding");
			await cache.put(entry.href, new Response(document, { headers }));
			await Promise.all([
				cache.add(bootstrap.href),
				cache.add(new URL("version.json", runtime).href),
			]);
			const warm = document.includes("beta-launcher.js")
				? [...shellFiles, ...channelFiles]
				: shellFiles;
			await Promise.allSettled(
				warm.map(async (name) => {
					const url = new URL(name, app).href;
					const response = await fetch(url);
					if (
						response.ok &&
						!response.headers.get("content-type")?.includes("text/html")
					) {
						await cache.put(url, response);
					}
				}),
			);
			await self.skipWaiting();
		})(),
	);
});
self.addEventListener("activate", (event) =>
	event.waitUntil(self.clients.claim()),
);

self.addEventListener("fetch", (event) => {
	const request = event.request;
	if (
		request.method !== "GET" ||
		request.headers.has("authorization") ||
		request.headers.has("range")
	)
		return;
	const url = new URL(request.url);
	// package_info_plus appends a new timestamp even when reading offline.
	const versionLookup =
		url.origin === app.origin &&
		/^version\.json$|^releases\/[a-z0-9-]+\/(?:stable\/)?version\.json$/.test(
			url.pathname.slice(app.pathname.length),
		) &&
		/^\?cachebuster=\d+$/.test(url.search);
	if (versionLookup) url.search = "";
	const navigation =
		request.mode === "navigate" &&
		url.origin === app.origin &&
		!url.search &&
		[app.pathname.slice(0, -1), app.pathname, entry.pathname].includes(
			url.pathname,
		);
	if (!navigation && !publicResource(url)) return;
	const key = navigation ? entry.href : versionLookup ? url.href : request;
	function cachedResponse(saved) {
		if (!saved || url.pathname !== app.pathname + "beta-release.json")
			return saved;
		const headers = new Headers(saved.headers);
		headers.set("X-Better-Keep-Offline", "1");
		return new Response(saved.body, { headers });
	}
	event.respondWith(
		(async () => {
			let cache;
			try {
				cache = await caches.open(cacheName);
			} catch {
				return fetch(request);
			}
			const immutable =
				url.origin !== app.origin ||
				/^releases\/|^beta-runtime\//.test(
					url.pathname.slice(app.pathname.length),
				);
			if (!self.navigator.onLine || immutable) {
				const saved = await cache.match(key);
				if (saved) return cachedResponse(saved);
			}
			let response;
			try {
				response = await fetch(request);
			} catch (error) {
				const saved = await cache.match(key);
				if (saved) return cachedResponse(saved);
				throw error;
			}
			if (
				response.ok &&
				!response.redirected &&
				(navigation ||
					!response.headers.get("content-type")?.includes("text/html"))
			) {
				event.waitUntil(cache.put(key, response.clone()).catch(() => {}));
			} else if (response.status >= 500) {
				return cachedResponse(await cache.match(key)) || response;
			}
			return response;
		})(),
	);
});

self.addEventListener("message", (event) => {
	if (
		event.data?.type !== "app-ready" ||
		event.data.base !== runtime.href ||
		new URL(event.source.url).origin !== app.origin ||
		!Array.isArray(event.data.resources)
	)
		return;
	event.waitUntil(
		(async () => {
			const cache = await caches.open(cacheName);
			const resources = new Set(
				bundledAssets.map((name) => new URL(name, runtime).href),
			);
			// Requests made inside an existing SQLite shared worker are absent from
			// the page's resource timings. Cache both files before an offline reopen.
			const betaRuntime = /^releases\/[a-z0-9-]+\/$/.test(
				runtime.pathname.slice(app.pathname.length),
			);
			const sqlite = betaRuntime ? new URL("beta-runtime/v1/", app) : app;
			for (const name of ["sqflite_sw.js", "sqlite3.wasm"]) {
				resources.add(new URL(name, sqlite).href);
			}
			for (const value of event.data.resources) {
				if (typeof value !== "string") continue;
				const url = new URL(value, runtime);
				if (publicResource(url)) resources.add(url.href);
			}
			// Bound first-visit downloads. Regular fetches refresh mutable assets.
			const queue = Array.from(resources);
			const versioned = runtime.pathname.includes("/releases/");
			async function warm() {
				while (queue.length) {
					const url = queue.pop();
					try {
						if (await cache.match(url)) continue;
						const response = await fetch(url);
						if (
							response.ok &&
							!response.redirected &&
							!response.headers.get("content-type")?.includes("text/html")
						)
							await cache.put(url, response);
					} catch {
						/* Offline, or the browser has reached its storage limit. */
					}
				}
			}
			await Promise.all(Array.from({ length: 4 }, warm));
			if (!versioned) return;
			const manifest = await cache.match(new URL("beta-release.json", app));
			if (!manifest) return;
			const { base, stableBase, stable } = await manifest.json();
			const retained = [base, stableBase, stable?.base];
			if (!retained.includes(runtime.pathname)) return;
			for (const key of await cache.keys()) {
				const path = new URL(key.url).pathname;
				const version = path.match(
					/^\/app\/releases\/[a-z0-9-]+\/(?:stable\/)?/,
				)?.[0];
				if (version && !retained.includes(version)) await cache.delete(key);
			}
		})(),
	);
});
