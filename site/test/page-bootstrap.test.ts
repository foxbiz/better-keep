import assert from 'node:assert/strict';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import { createHomeRedirectBootstrap, pageBootstrap } from '../src/lib/page-bootstrap.ts';
import { createStorePlatformBootstrap } from '../src/lib/store-platform.ts';

test('query cleanup preserves the path and fragment without retaining account parameters', () => {
  const calls: unknown[][] = [];
  const window = {
    location: { search: '?uid=private', pathname: '/account/manage', hash: '#billing' },
    history: { replaceState: (...args: unknown[]) => { calls.push(args); } }
  };
  runInNewContext(pageBootstrap.query, { window });
  assert.deepEqual(calls, [[null, '', '/account/manage#billing']]);
  window.location.search = '';
  runInNewContext(pageBootstrap.query, { window });
  assert.equal(calls.length, 1);
});

test('the analytics bootstrap queues only labeled links with their placement', () => {
  let onClick: (event: { target: unknown }) => void = () => assert.fail('Click handler missing');
  class Link {
    textContent = '  App Store  ';
    closest() { return this; }
    getAttribute() { return 'App Store Click'; }
  }
  const window: {
    location: { pathname: string };
    plausible?: { q?: IArguments[] };
  } = { location: { pathname: '/' } };
  runInNewContext(pageBootstrap.analytics, {
    window,
    document: { addEventListener: (_name: string, listener: typeof onClick) => { onClick = listener; } },
    Element: Link
  });
  onClick({ target: new Link() });
  onClick({ target: {} });
  const queue = window.plausible?.q;
  assert.equal(queue?.length, 1);
  assert.equal(queue?.[0][0], 'App Store Click');
  assert.equal(queue?.[0][1].props.path, '/');
  assert.equal(queue?.[0][1].props.placement, 'App Store');
});

test('legacy standalone installs open the app only from the website root', () => {
  for (const [standalone, pathname, expected] of [
    [true, '/', '/app/'], [true, '/security', null], [false, '/', null]
  ] as const) {
    let destination: string | null = null;
    const window = {
      matchMedia: () => ({ matches: false }),
      navigator: { standalone },
      location: { pathname, search: '', replace: (url: string) => { destination = url; } }
    };
    runInNewContext(createHomeRedirectBootstrap({}), { window, document: {}, URLSearchParams });
    assert.equal(destination, expected);
  }
});

test('homepage store redirects use detected platforms and preserve unsupported pages', () => {
  const stores = { apple: 'https://apps.apple.com/app', google: 'https://play.google.com/store/apps', microsoft: 'https://apps.microsoft.com/detail/app' };
  const cases = [
    ['iPhone', '/', '?redirect=store', stores.apple],
    ['iPad', '/', '?redirect=store', stores.apple],
    ['MacIntel', '/', '?redirect=store', stores.apple],
    ['Android', '/', '?utm_source=qr&redirect=store', stores.google],
    ['Windows', '/', '?redirect=store', stores.microsoft],
    ['Linux', '/', '?redirect=store', null],
    ['CrOS', '/', '?redirect=store', null],
    ['', '/', '?redirect=store', null],
    ['Android', '/pricing', '?redirect=store', null],
    ['Android', '/', '?redirect=https://example.com', null],
    ['Android', '/', '', null]
  ] as const;
  for (const [platform, pathname, search, expected] of cases) {
    let destination: string | null = null;
    const navigator = { userAgent: platform, platform, standalone: false };
    const document = { documentElement: { dataset: {} } };
    const window = {
      navigator,
      matchMedia: () => ({ matches: false }),
      location: { pathname, search, replace: (url: string) => { destination = url; } }
    };
    const context = { window, document, navigator, URLSearchParams };
    runInNewContext(createStorePlatformBootstrap(), context);
    const redirect = createHomeRedirectBootstrap(stores);
    runInNewContext(redirect, context);
    assert.equal(destination, expected, `${platform} ${pathname}${search}`);
    if (search === '?redirect=store' && pathname === '/') {
      // Explicit store requests take precedence over the installed PWA shortcut,
      // including when there is no destination for the detected platform.
      navigator.standalone = true;
      destination = null;
      runInNewContext(redirect, context);
      assert.equal(destination, expected);
      destination = null;
      runInNewContext(createHomeRedirectBootstrap({}), context);
      assert.equal(destination, null);
    }
  }
});
