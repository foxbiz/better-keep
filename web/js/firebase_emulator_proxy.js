// FlutterFire's emulator helpers generate HTTP URLs. Debug builds can route
// those exact endpoints through an HTTPS development proxy before SDK startup.
(() => {
  let routes = new Map();
  let installed = false;
  const services = {9099: 'auth', 8080: 'firestore', 5001: 'functions', 9199: 'storage'};
  const rewrite = (value) => {
    const url = new URL(value, location.href);
    const destination = routes.get(url.origin);
    return destination ? `${destination}${url.pathname}${url.search}` : value;
  };

  // FlutterFire initializes Auth (including persisted-session validation) while
  // initializing an app. Route that instance synchronously before it can send
  // requests. A sessionStorage hint is not evidence of actual SDK routing.
  window.betterKeepPrepareAuthEmulator = (appName, options, host, port) => {
    if (!appName.startsWith('better-keep-emulator-')) {
      throw new Error('Emulator Auth requires a dedicated emulator app.');
    }
    const origin = new URL(`http://${host}:${port}`).origin;
    const app = window.firebase_core.initializeApp(options, appName);
    const sdk = window.firebase_auth;
    // Match firebase_auth_web's dependencies so its initializeAuth call reuses
    // this same instance, including the existing IndexedDB session.
    const auth = sdk.initializeAuth(app, {
      errorMap: sdk.debugErrorMap,
      persistence: [sdk.indexedDBLocalPersistence, sdk.browserLocalPersistence,
        sdk.browserSessionPersistence],
      popupRedirectResolver: sdk.browserPopupRedirectResolver,
    });
    const configured = auth.emulatorConfig;
    if (configured) {
      if (new URL(`${configured.protocol}://${configured.host}:${configured.port}`).origin !== origin) {
        throw new Error('Auth is configured for a different emulator.');
      }
    } else {
      sdk.connectAuthEmulator(auth, origin);
    }
    // Only publish the FlutterFire hint after the SDK has been configured.
    window.sessionStorage.setItem(`${appName}-firebaseEmulatorOrigin`, origin);
  };

  window.betterKeepConfigureEmulatorProxy = (host, origin) => {
    const destination = new URL(origin);
    if (destination.protocol !== 'https:' || destination.username ||
        destination.password || destination.pathname !== '/' ||
        destination.search || destination.hash) {
      throw new Error('The emulator proxy must be an HTTPS origin.');
    }
    routes = new Map(Object.entries(services).map(([port, service]) => [
      new URL(`http://${host}:${port}`).origin,
      `${destination.origin}/__emulator/${service}`,
    ]));
    if (installed) return;
    installed = true;
    const originalFetch = window.fetch;
    window.fetch = function(input, init) {
      const url = input instanceof Request ? input.url : String(input);
      const target = rewrite(url);
      return originalFetch.call(this,
        target === url ? input : input instanceof Request ? new Request(target, input) : target,
        init);
    };
    const originalOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url, ...args) {
      return originalOpen.call(this, method, rewrite(String(url)), ...args);
    };
  };
})();
