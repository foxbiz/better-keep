import assert from 'node:assert/strict';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import { pageBootstrap } from '../src/lib/page-bootstrap.ts';

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
      location: { pathname, replace: (url: string) => { destination = url; } }
    };
    runInNewContext(pageBootstrap.legacy, { window });
    assert.equal(destination, expected);
  }
});
