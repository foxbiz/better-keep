import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import test from 'node:test';
import {
  STORE_PLATFORMS,
  createStorePlatformBootstrap,
  detectStorePlatform
} from '../site/src/lib/store-platform.mjs';

test('detects every supported native store from client hints', () => {
  const cases = new Map([
    ['Android', 'google'],
    ['Windows', 'microsoft'],
    ['Windows 11', 'microsoft'],
    ['macOS', 'apple'],
    ['iOS', 'apple'],
    ['iPad', 'apple']
  ]);

  for (const [userAgentDataPlatform, expected] of cases) {
    assert.equal(detectStorePlatform({ userAgentDataPlatform }), expected);
  }
  assert.deepEqual(STORE_PLATFORMS, ['apple', 'google', 'microsoft']);
});

test('uses legacy user-agent and navigator platform fallbacks', () => {
  const cases = [
    [{ userAgent: 'Mozilla/5.0 (Linux; Android 15)' }, 'google'],
    [{ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 19_0)' }, 'apple'],
    [{ userAgent: 'Mozilla/5.0 (iPad; CPU OS 19_0)' }, 'apple'],
    [{ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)' }, 'apple'],
    [{ platform: 'MacIntel' }, 'apple'],
    [{ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }, 'microsoft'],
    [{ platform: 'Win32' }, 'microsoft']
  ];

  for (const [signals, expected] of cases) {
    assert.equal(detectStorePlatform(signals), expected);
  }
});

test('returns no native badge for ChromeOS, Linux, and unknown devices', () => {
  for (const signals of [
    { userAgentDataPlatform: 'Chrome OS' },
    { userAgent: 'Mozilla/5.0 (X11; CrOS x86_64)' },
    { userAgentDataPlatform: 'Linux' },
    { userAgent: 'Mozilla/5.0 (X11; Linux x86_64)' },
    { userAgent: 'A future browser' },
    {}
  ]) {
    assert.equal(detectStorePlatform(signals), null);
  }
});

test('recognized client hints take precedence over legacy strings', () => {
  assert.equal(
    detectStorePlatform({
      userAgentDataPlatform: 'Windows',
      userAgent: 'Mozilla/5.0 (Linux; Android 15)',
      platform: 'Linux armv8l'
    }),
    'microsoft'
  );
  assert.equal(
    detectStorePlatform({
      userAgentDataPlatform: 'Chrome OS',
      userAgent: 'Mozilla/5.0 (Windows NT 10.0)',
      platform: 'Win32'
    }),
    null
  );
});

test('the synchronous bootstrap sets only the root platform attribute', () => {
  const document = { documentElement: { dataset: {} } };
  const navigator = {
    platform: 'MacIntel',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)',
    userAgentData: { platform: 'macOS' }
  };
  const source = createStorePlatformBootstrap();

  runInNewContext(source, { document, navigator });
  assert.equal(document.documentElement.dataset.storePlatform, 'apple');
  assert.doesNotMatch(source, /fetch\(|localStorage|sessionStorage|plausible/i);
});

test('the synchronous bootstrap uses none for unsupported platforms', () => {
  const document = { documentElement: { dataset: {} } };
  const navigator = {
    platform: 'Linux x86_64',
    userAgent: 'Mozilla/5.0 (X11; Linux x86_64)',
    userAgentData: { platform: 'Linux' }
  };

  runInNewContext(createStorePlatformBootstrap(), { document, navigator });
  assert.equal(document.documentElement.dataset.storePlatform, 'none');
});
