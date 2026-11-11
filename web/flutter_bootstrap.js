{{flutter_js}}
{{flutter_build_config}}

(() => {
  const runtime = new URL("./", document.currentScript.src);
  const release = _flutter.buildConfig.builds.some(build =>
    build.compileTarget === "dart2js" || build.compileTarget === "dart2wasm");
  async function prepareOffline() {
    const workers = navigator.serviceWorker;
    if (!workers || !runtime.pathname.startsWith("/app/")) return;
    const script = new URL("offline_worker.js", runtime);
    window.addEventListener("flutter-first-frame", () => {
      const resources = performance.getEntriesByType("resource").map(entry => entry.name).filter(name => {
        const url = new URL(name);
        return !url.search && !url.hash && (url.href.startsWith(runtime.href) ||
          url.href.startsWith("https://www.gstatic.com/firebasejs/") || url.href.startsWith("https://fonts.gstatic.com/s/"));
      });
      // The previous channel may still control this page at first frame.
      // Warm each matching controller when it actually takes over.
      let warmed;
      function warmController() {
        const worker = workers.controller;
        if (!worker || worker.scriptURL !== script.href || worker === warmed) return;
        worker.postMessage({type: "app-ready", base: runtime.href, resources});
        warmed = worker;
      }
      workers.addEventListener("controllerchange", warmController);
      warmController();
    }, {once: true});
    const registered = workers.register(script, {scope: "/app", updateViaCache: "none"});
    if (workers.controller) {
      registered.catch(() => {});
      return;
    }
    await registered;
    await workers.ready;
    if (!workers.controller) await new Promise(resolve =>
      workers.addEventListener("controllerchange", resolve, {once: true}));
  }
  async function start() {
    if (!release) return _flutter.loader.load();
    // The app also works in browsers that disable service workers.
    await Promise.race([prepareOffline().catch(() => {}), new Promise(resolve => setTimeout(resolve, 4000))]);
    return _flutter.loader.load({config: {
      entrypointBaseUrl: runtime.href, assetBase: runtime.href, canvasKitBaseUrl: runtime.href + "canvaskit/",
    }});
  }
  start();
})();
