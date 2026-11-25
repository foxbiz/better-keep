import { chromeBinary } from "../../tool/chrome_binary.mjs";
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import puppeteer from 'puppeteer-core';

// All requests are intercepted. This uses the real browser Auth SDK and real
// IndexedDB persistence, but never sends credentials to any Firebase project.
const sdkDirectory = process.env.FIREBASE_TEST_SDK_DIR ?? 'node_modules/firebase';
const authSource = readFileSync(path.join(sdkDirectory, 'firebase-auth.js'), 'utf8');
const appSource = readFileSync(path.join(sdkDirectory, 'firebase-app.js'), 'utf8');
const appUrl = authSource.match(/https:\/\/www\.gstatic\.com\/firebasejs\/[^"']+\/firebase-app\.js/)[0];
const authUrl = appUrl.replace('firebase-app.js', 'firebase-auth.js');
const proxySource = readFileSync('web/js/firebase_emulator_proxy.js', 'utf8');
const origin = 'https://auth-routing.example.test';
const name = 'better-keep-emulator-reload-regression';
const options = {apiKey: 'fake-api-key', appId: 'fake-app-id', projectId: 'demo-routing-test', authDomain: 'demo-routing-test.firebaseapp.com', databaseURL: null, storageBucket: null, messagingSenderId: 'qa-sender', measurementId: null};

function idToken() {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({alg: 'none'})}.${encode({sub: 'qa-user', user_id: 'qa-user', aud: options.projectId, iss: `https://securetoken.google.com/${options.projectId}`, iat: Math.floor(Date.now()/1000), exp: Math.floor(Date.now()/1000)+3600, auth_time: Math.floor(Date.now()/1000), firebase: {sign_in_provider: 'google.com'}})}.`;
}

test('HTTPS Auth restores the same emulator user after reload and reuses routing on hot restart', {timeout: 60000}, async () => {
  const browser = await puppeteer.launch({
    executablePath: chromeBinary(),
    headless: true,
  });
  try {
    const page = await browser.newPage();
    const blocked = [];
    const authRequests = [];
    await page.setRequestInterception(true);
    page.on('request', async (request) => {
      const url = request.url();
      if (url === `${origin}/`) {
        await request.respond({contentType: 'text/html', body: '<html><body>Isolated Auth routing test</body></html>'});
      } else if (url === appUrl || url === authUrl) {
        await request.respond({contentType: 'application/javascript', headers: {'Access-Control-Allow-Origin': '*'}, body: url === appUrl ? appSource : authSource});
      } else if (url.startsWith(`${origin}/__emulator/auth/`)) {
        authRequests.push(new URL(url).pathname);
        let body;
        if (url.includes('accounts:signInWithIdp')) {
          body = {localId: 'qa-user', email: 'qa@emulator.test', providerId: 'google.com', idToken: idToken(), refreshToken: 'fake-refresh-token', expiresIn: '3600'};
        } else if (url.includes('accounts:lookup')) {
          body = {users: [{localId: 'qa-user', email: 'qa@emulator.test', emailVerified: true, providerUserInfo: [{providerId: 'google.com', rawId: 'qa-google-user', email: 'qa@emulator.test'}]}]};
        } else {
          blocked.push(url);
          return request.abort();
        }
        await request.respond({contentType: 'application/json', body: JSON.stringify(body)});
      } else if (url.endsWith('/favicon.ico')) {
        await request.respond({status: 204});
      } else {
        blocked.push(url);
        await request.abort();
      }
    });
    const start = async () => {
      await page.addScriptTag({content: proxySource});
      return page.evaluate(async ({appUrl, authUrl, origin, name, options}) => {
        window.firebase_core = await import(appUrl);
        window.firebase_auth = await import(authUrl);
        // Simulate the stale FlutterFire hint retained across an HTTPS reload.
        sessionStorage.setItem(`${name}-firebaseEmulatorOrigin`, 'http://127.0.0.1:9099');
        window.betterKeepConfigureEmulatorProxy('127.0.0.1', origin);
        window.betterKeepPrepareAuthEmulator(name, options, '127.0.0.1', 9099);
        const sdk = window.firebase_auth;
        const app = window.firebase_core.initializeApp(options, name);
        // FlutterFire initializes again with precisely these dependencies.
        const auth = sdk.initializeAuth(app, {errorMap: sdk.debugErrorMap, persistence: [sdk.indexedDBLocalPersistence, sdk.browserLocalPersistence, sdk.browserSessionPersistence], popupRedirectResolver: sdk.browserPopupRedirectResolver});
        await auth.authStateReady();
        window.qaAuth = auth;
        return {uid: auth.currentUser?.uid ?? null, host: auth.emulatorConfig.host};
      }, {appUrl, authUrl, origin, name, options});
    };
    await page.goto(origin);
    assert.deepEqual(await start(), {uid: null, host: '127.0.0.1'});
    const uid = await page.evaluate(async () => {
      const sdk = window.firebase_auth;
      const credential = sdk.GoogleAuthProvider.credential(JSON.stringify({sub: 'qa-google-user', email: 'qa@emulator.test'}));
      return (await sdk.signInWithCredential(window.qaAuth, credential)).user.uid;
    });
    assert.equal(uid, 'qa-user');
    await page.reload();
    assert.deepEqual(await start(), {uid: 'qa-user', host: '127.0.0.1'});
    const lookups = authRequests.filter((url) => url.includes('accounts:lookup')).length;
    assert.ok(lookups > 0, 'restored user must be validated through the emulator proxy');
    assert.deepEqual(await start(), {uid: 'qa-user', host: '127.0.0.1'});
    assert.ok(authRequests.some((url) => url.includes('accounts:signInWithIdp')));
    assert.deepEqual(blocked, [], 'no production Auth or other network requests');
  } finally {
    await browser.close();
  }
});
