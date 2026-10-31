import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {runInNewContext} from 'node:vm';

const html = readFileSync(new URL('../../web/storage-auth.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const nonce = 'a'.repeat(43);

function run(query, hasOpener = false) {
  const url = new URL(`https://dev.example.test/oauth/storage/callback?${query}`);
  const result = {messages: [], redirects: [], closed: false, cleaned: null};
  const elements = {'status': {textContent: ''}, 'open-app': {hidden: true}};
  runInNewContext(script, {
    URL,
    window: {
      location: {href: url.href, pathname: url.pathname, origin: url.origin,
        replace: (target) => result.redirects.push(target)},
      opener: hasOpener ? {postMessage: (message, origin) => result.messages.push({message, origin})} : null,
      close: () => { result.closed = true; },
    },
    document: {getElementById: (id) => elements[id]},
    history: {replaceState: (_state, _title, path) => { result.cleaned = path; }},
  });
  return {...result, elements};
}

test('native callbacks automatically open the fixed app scheme and retain a fallback', () => {
  const result = run(`state=app.${nonce}&code=single-use&returnUrl=https://attacker.test`, true);
  const target = new URL(result.redirects[0]);
  assert.equal(target.origin, 'null');
  assert.equal(target.protocol, 'betterkeep-storage:');
  assert.equal(target.host, 'oauth');
  assert.equal(target.pathname, '/callback');
  assert.equal(target.searchParams.get('code'), 'single-use');
  assert.equal(target.searchParams.get('state'), `app.${nonce}`);
  assert.equal(target.searchParams.has('returnUrl'), false);
  assert.equal(result.elements['open-app'].href, target.href);
  assert.equal(result.elements['open-app'].hidden, false);
  assert.equal(result.messages.length, 0);
  assert.equal(result.cleaned, '/oauth/storage/callback');
});

test('desktop callbacks only target a bounded IPv4 loopback port', () => {
  const result = run(`state=loopback.23456.${nonce}&code=one-time`);
  const target = new URL(result.redirects[0]);
  assert.equal(target.origin, 'http://127.0.0.1:23456');
  assert.equal(target.pathname, '/storage-oauth');
});

test('denial returns to the app without fabricating a successful code', () => {
  const result = run(`state=app.${nonce}&error=access_denied`);
  const target = new URL(result.redirects[0]);
  assert.equal(target.searchParams.get('error'), 'access_denied');
  assert.equal(target.searchParams.has('code'), false);
});

test('web callbacks preserve the opener message and close the tab', () => {
  const result = run(`state=${nonce}&code=single-use`, true);
  assert.equal(result.messages.length, 1);
  assert.equal(result.messages[0].origin, 'https://dev.example.test');
  assert.equal(result.messages[0].message.type, 'betterkeep-storage-oauth');
  assert.equal(new URL(result.messages[0].message.url).searchParams.get('code'), 'single-use');
  assert.equal(result.closed, true);
  assert.equal(result.redirects.length, 0);
});

test('malformed, ambiguous or arbitrary destinations never redirect or message', () => {
  for (const query of [
    `state=app.${nonce}&code=a&code=b`,
    `state=app.${nonce}&state=app.${nonce}&code=a`,
    `state=app.${nonce}&code=a&error=denied`,
    `state=app.${nonce}&error=a&error=b`,
    `state=app.${nonce}&code=`,
    `state=app.${nonce}&code=${'a'.repeat(8193)}`,
    `state=loopback.1023.${nonce}&code=a`,
    `state=loopback.65536.${nonce}&code=a`,
    `state=loopback.evil.test.${nonce}&code=a`,
    `state=https://attacker.test&code=a`,
    `state=app.${nonce}&code=a#fragment`,
    `code=a`,
  ]) {
    const result = run(query, true);
    assert.equal(result.redirects.length, 0);
    assert.equal(result.messages.length, 0);
    assert.equal(result.elements['open-app'].hidden, true);
    assert.match(result.elements.status.textContent, /invalid/);
  }
});

 test('hosting CSP binds the exact callback script and disallows other scripts', async () => {
 const {createHash} = await import('node:crypto');
 const {readFileSync} = await import('node:fs');
 const page = readFileSync('web/storage-auth.html','utf8');
 const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
 const hash = createHash('sha256').update(script).digest('base64');
 const config = JSON.parse(readFileSync('firebase.deploy.json','utf8'));
 const headers = config.hosting[0].headers.find(h => h.source.includes('oauth/storage/callback')).headers;
 const csp = headers.find(h => h.key === 'Content-Security-Policy').value;
 assert.ok(csp.includes(`script-src 'sha256-${hash}'`));
 assert.ok(csp.includes("base-uri 'none'"));
 assert.ok(csp.includes("object-src 'none'"));
 });
