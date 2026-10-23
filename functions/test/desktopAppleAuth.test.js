const assert = require("node:assert/strict");
const test = require("node:test");
const vm = require("node:vm");
const fs = require("node:fs");
const { renderDesktopAppleSignIn, validateDesktopAppleCompletion } = require("../lib/desktopAppleAuth");
const { sealOAuthState, openOAuthState, OAUTH_STATE_AUDIENCE } = require("../lib/oauthSession");

const now = Date.now();
const state = {
  version: 2, audience: OAUTH_STATE_AUDIENCE, provider: "apple", mode: "signin",
  redirect: "betterkeep", browserNonce: "a".repeat(43), issuedAt: now,
  expiresAt: now + 300000, clientTransactionId: "b".repeat(22), completionChallenge: "c".repeat(43),
};
const token = { uid: "existing-apple-user", firebase: { sign_in_provider: "apple.com" }, auth_time: Math.floor(now / 1000) };

test("Apple browser state uses the existing authenticated, expiring envelope", async () => {
  const secret = Buffer.alloc(32, 4).toString("base64url");
  const sealed = await sealOAuthState(state, secret);
  assert.deepEqual(await openOAuthState(sealed, secret, now), state);
  await assert.rejects(openOAuthState(sealed, secret, now + 300001));
  await assert.rejects(openOAuthState(sealed, Buffer.alloc(32, 5).toString("base64url"), now));
});

test("completion requires the initiating browser and a fresh Apple authentication", () => {
  assert.doesNotThrow(() => validateDesktopAppleCompletion(state, state.browserNonce, token));
  for (const cookie of [null, "x".repeat(43)]) {
    assert.throws(() => validateDesktopAppleCompletion(state, cookie, token));
  }
  for (const other of [
    { ...token, firebase: { sign_in_provider: "custom" } },
    { ...token, firebase: { sign_in_provider: "google.com" } },
    { ...token, auth_time: Math.floor(now / 1000) - 60 },
    { ...token, auth_time: undefined },
  ]) {
    assert.throws(() => validateDesktopAppleCompletion(state, state.browserNonce, other));
  }
  for (const changes of [{ provider: "github" }, { mode: "link" }, { redirect: "popup" }, { version: 1 }]) {
    assert.throws(() => validateDesktopAppleCompletion({ ...state, ...changes }, state.browserNonce, token));
  }
});

async function browserHarness({ popupError, completionStatus = true } = {}) {
  const page = renderDesktopAppleSignIn("sealed-state", state.clientTransactionId);
  const script = page.html.match(/<script type="module"[^>]*>([\s\S]*?)<\/script>/)[1]
    .replace(/^import .*;$/gm, "");
  const elements = Object.fromEntries(["signin", "status", "return", "cancel"].map(id => [id, {}]));
  const requests = [];
  const navigations = [];
  let persistence;
  let initializedConfig;
  const hostingConfig = {
    projectId: "better-keep-notes",
    appId: "test-web-app",
    apiKey: "test-api-key",
    authDomain: "better-keep-notes.firebaseapp.com",
  };
  let signedOut = 0;
  const context = {
    document: { getElementById: id => elements[id] },
    window: { location: { assign: url => navigations.push(url) } },
    URLSearchParams,
    initializeApp: config => { initializedConfig = config; return config; },
    inMemoryPersistence: "memory-only",
    browserPopupRedirectResolver: {},
    initializeAuth: (_app, options) => { persistence = options.persistence; return {}; },
    OAuthProvider: class { constructor(id) { assert.equal(id, "apple.com"); } addScope() {} },
    signInWithPopup: async () => {
      if (popupError) throw popupError;
      return { user: { getIdToken: async () => "sensitive-id-token" } };
    },
    signOut: async () => { signedOut++; },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (url === "/__/firebase/init.json") return { ok: true, json: async () => ({ ...hostingConfig }) };
      assert.equal(url, "/oauth/apple");
      return { ok: completionStatus, json: async () => ({ code: "one-time-code" }) };
    },
  };
  await vm.runInNewContext(`(async () => {${script}})()`, context);
  assert.equal(elements.signin.disabled, false);
  await elements.signin.onclick();
  return { requests, navigations, elements, persistence, signedOut, initializedConfig, hostingConfig };
}

test("Apple popup preserves the configured custom auth domain instead of Hosting's default", async () => {
  const { initializedConfig, hostingConfig } = await browserHarness();
  assert.deepEqual({ ...initializedConfig }, {
    ...hostingConfig,
    authDomain: "betterkeep.app",
  });
  assert.equal(hostingConfig.authDomain, "better-keep-notes.firebaseapp.com");
});

test("browser keeps auth in memory and returns only the one-time completion code", async () => {
  const result = await browserHarness();
  assert.equal(result.persistence, "memory-only");
  assert.equal(result.signedOut, 1);
  const post = result.requests[1];
  assert.equal(post.options.method, "POST");
  assert.equal(post.options.credentials, "same-origin");
  assert.deepEqual(JSON.parse(post.options.body), { state: "sealed-state", idToken: "sensitive-id-token" });
  const callback = new URL(result.navigations[0]);
  assert.equal(callback.protocol, "betterkeep:");
  assert.equal(callback.searchParams.get("transactionId"), state.clientTransactionId);
  assert.equal(callback.searchParams.get("code"), "one-time-code");
  assert.ok(!callback.href.includes("sensitive-id-token"));
  assert.equal(result.elements.return.href, callback.href);
});

test("closing Apple's popup returns cancellation for the same transaction", async () => {
  const result = await browserHarness({ popupError: { code: "auth/popup-closed-by-user" } });
  assert.equal(result.requests.length, 1);
  const callback = new URL(result.navigations[0]);
  assert.equal(callback.searchParams.get("cancelled"), "true");
  assert.equal(callback.searchParams.get("transactionId"), state.clientTransactionId);
});

test("failed completion never returns a success deep link", async () => {
  const result = await browserHarness({ completionStatus: false });
  assert.equal(result.navigations.length, 0);
  assert.equal(result.elements.signin.disabled, false);
  assert.match(result.elements.status.textContent, /expired/);
});

test("rendered state cannot break out of the script and CSP disallows framing", () => {
  const page = renderDesktopAppleSignIn("</script><script>attack()</script>", state.clientTransactionId);
  assert.ok(!page.html.includes("<script>attack()"));
  assert.match(page.contentSecurityPolicy, /frame-ancestors 'none'/);
  assert.match(page.contentSecurityPolicy, /script-src 'nonce-/);
});

// Exercise the actual HTTP handler while replacing only Firebase/network IO.
async function endpointHarness() {
  const secret = Buffer.alloc(32, 6).toString("base64url");
  const completions = [];
  const verified = [];
  const loadedUsers = [];
  const exports = {};
  const dependencies = {
    "firebase-functions/v2/https": { onRequest: (_options, handler) => handler },
    "../config": {
      isEmulator: true,
      oauthStateSecret: { value: () => secret },
      auth: {
        verifyIdToken: async (value, checkRevoked) => {
          verified.push({ value, checkRevoked });
          if (value !== "valid-apple-id-token") throw new Error("Invalid token");
          return token;
        },
        getUser: async uid => { loadedUsers.push(uid); return { uid }; },
      },
    },
    "../desktopAppleAuth": require("../lib/desktopAppleAuth"),
    "../oauthSession": require("../lib/oauthSession"),
    "../oauthCompletion": {
      createOAuthCompletion: async data => { completions.push(data); return "opaque-completion"; },
    },
    "../reviewAccess": { isProtectedReviewUserRecord: () => false },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve("../lib/exports/desktopAppleAuth"), "utf8"), {
    exports, require: name => {
      assert.ok(dependencies[name], `Unexpected dependency: ${name}`);
      return dependencies[name];
    },
  });
  const sealed = await sealOAuthState(state, secret);
  async function request({ method = "POST", origin = "https://betterkeep.app", cookie = `__session=${state.browserNonce}`, body = { state: sealed, idToken: "valid-apple-id-token" }, query = {} } = {}) {
    const response = { headers: {}, statusCode: 200, body: null };
    const res = {
      set: (key, value) => { response.headers[key] = value; return res; },
      status: value => { response.statusCode = value; return res; },
      type: () => res,
      send: value => { response.body = value; return res; },
      json: value => { response.body = value; return res; },
    };
    await exports.default({ method, query, body, get: name => ({ origin, cookie })[name], is: value => value === "application/json" }, res);
    return response;
  }
  return { request, completions, verified, loadedUsers, sealed };
}

test("HTTP completion preserves the verified Apple UID and verifier binding", async () => {
  const harness = await endpointHarness();
  const result = await harness.request();
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.code, "opaque-completion");
  assert.equal(result.headers["Cache-Control"], "no-store");
  assert.match(result.headers["Set-Cookie"], /Max-Age=0/);
  assert.deepEqual(harness.verified, [{ value: "valid-apple-id-token", checkRevoked: true }]);
  assert.deepEqual(harness.loadedUsers, [token.uid]);
  assert.equal(harness.completions[0].uid, token.uid);
  assert.equal(harness.completions[0].provider, "apple");
  assert.equal(harness.completions[0].challenge, state.completionChallenge);
  assert.equal(harness.completions[0].clientTransactionId, state.clientTransactionId);
});

test("HTTP completion rejects cross-origin, wrong-browser and invalid-token requests", async () => {
  const harness = await endpointHarness();
  assert.equal((await harness.request({ origin: "https://attacker.example" })).statusCode, 400);
  assert.equal(harness.verified.length, 0);
  assert.equal((await harness.request({ cookie: "" })).statusCode, 403);
  assert.equal((await harness.request({ cookie: `__session=${"x".repeat(43)}` })).statusCode, 403);
  assert.equal((await harness.request({ body: { state: "tampered-state", idToken: "valid-apple-id-token" } })).statusCode, 403);
  assert.equal((await harness.request({ body: { state: harness.sealed, idToken: "invalid-token" } })).statusCode, 403);
  assert.equal(harness.completions.length, 0);
});

test("HTTP start only accepts Windows Apple sign-in and sets a protected browser cookie", async () => {
  const harness = await endpointHarness();
  const query = { provider: "apple", mode: "signin", redirect: "betterkeep", flowVersion: "2", completionChallenge: state.completionChallenge, clientTransactionId: state.clientTransactionId };
  const result = await harness.request({ method: "GET", query });
  assert.equal(result.statusCode, 200);
  assert.match(result.body, /Continue with Apple/);
  assert.match(result.headers["Set-Cookie"], /Secure; HttpOnly; SameSite=Lax/);
  for (const changes of [{ mode: "link" }, { provider: "github" }, { redirect: "popup" }, { flowVersion: "1" }, { completionChallenge: "bad" }]) {
    assert.equal((await harness.request({ method: "GET", query: { ...query, ...changes } })).statusCode, 400);
  }
  assert.equal((await harness.request({ method: "DELETE" })).statusCode, 405);
  assert.equal(harness.completions.length, 0);
});
