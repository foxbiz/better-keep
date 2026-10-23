import assert from 'node:assert/strict';
import test from 'node:test';
import { configureNativeAppAction } from '../src/lib/native-app-action.ts';

const playStoreUrl = 'https://play.google.com/store/apps/details?id=io.foxbiz.better_keep&utm_source=betterkeep.app';

function configure(hints: {
  userAgent?: string;
  platform?: string;
  maxTouchPoints?: number;
  userAgentData?: { platform?: string };
}) {
  const label = { textContent: 'Open web app' };
  const link = {
    href: '/app/',
    dataset: { analytics: 'open_web_app', playStoreUrl },
    querySelector: () => label
  };
  configureNativeAppAction(link as unknown as HTMLAnchorElement, {
    userAgent: '', platform: '', maxTouchPoints: 0, ...hints
  });
  return { link, label };
}

test('Android opens the registered app route with a tracked Play Store fallback', () => {
  const { link, label } = configure({
    userAgent: 'Mozilla/5.0 (Linux; Android 16)',
    platform: 'Linux armv8l',
    userAgentData: { platform: 'Android' }
  });
  assert.equal(label.textContent, 'Open app');
  assert.equal(link.dataset.analytics, 'open_native_app');
  assert.equal(link.href, `intent://auth#Intent;scheme=betterkeep;package=io.foxbiz.better_keep;S.browser_fallback_url=${encodeURIComponent(playStoreUrl)};end`);
});

test('iPhones and both iPad browser modes open the native app', () => {
  for (const hints of [
    { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 19_0)' },
    { userAgent: 'Mozilla/5.0 (iPad; CPU OS 19_0)' },
    { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)', platform: 'MacIntel', maxTouchPoints: 5 }
  ]) {
    const { link, label } = configure(hints);
    assert.equal(link.href, 'betterkeep://');
    assert.equal(label.textContent, 'Open app');
    assert.equal(link.dataset.analytics, 'open_native_app');
  }
});

test('desktop and unknown browsers keep the web action even at mobile widths', () => {
  for (const hints of [
    { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)', platform: 'MacIntel' },
    { userAgentData: { platform: 'Windows' }, maxTouchPoints: 10 },
    { userAgentData: { platform: 'Linux' } },
    { userAgentData: { platform: 'Chrome OS' } },
    {}
  ]) {
    const { link, label } = configure(hints);
    assert.equal(link.href, '/app/');
    assert.equal(label.textContent, 'Open web app');
    assert.equal(link.dataset.analytics, 'open_web_app');
  }
});

test('pages without a floating action remain safe to initialize', () => {
  configureNativeAppAction(null, { userAgent: '', platform: '', maxTouchPoints: 0 });
});
