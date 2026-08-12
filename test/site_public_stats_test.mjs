import assert from 'node:assert/strict';
import test from 'node:test';
import {
  USER_COUNT_LOADING_STATE,
  USER_COUNT_UNAVAILABLE_STATE,
  compactUserCount,
  createUserCountPresentation,
  loadPublicUserMetric,
  resolvePublicUserMetric
} from '../site/src/lib/public-stats.mjs';

test('compacts privacy-rounded community counts', () => {
  assert.equal(compactUserCount('4200+'), '4.2K+');
  assert.equal(compactUserCount('4500+'), '4.5K+');
  assert.equal(compactUserCount('1000+'), '1K+');
  assert.equal(compactUserCount('12500+'), '12.5K+');
  assert.equal(compactUserCount('1200000+'), '1.2M+');
  assert.equal(compactUserCount('950+'), '950+');
  for (const value of ['0', 'error', '4.22K+', '', null, 4200]) {
    assert.equal(compactUserCount(value), null, String(value));
  }
});

test('prefers the compact metric and falls back to the legacy message', () => {
  assert.equal(
    resolvePublicUserMetric({ metric: '4.2K+', message: '4200+' }),
    '4.2K+'
  );
  assert.equal(resolvePublicUserMetric({ message: '4500+' }), '4.5K+');
  assert.equal(resolvePublicUserMetric({ message: 'error' }), null);
  assert.equal(resolvePublicUserMetric({ message: '0' }), null);
  assert.equal(resolvePublicUserMetric(null), null);
});

test('loads ready and unavailable user-count states', async () => {
  assert.deepEqual(USER_COUNT_LOADING_STATE, { status: 'loading', metric: null });
  const ready = await loadPublicUserMetric({
    endpoint: 'https://example.test/stats',
    fetcher: async () => ({
      ok: true,
      json: async () => ({ message: '4200+' })
    })
  });
  assert.deepEqual(ready, { status: 'ready', metric: '4.2K+' });

  for (const fetcher of [
    async () => ({ ok: false }),
    async () => ({ ok: true, json: async () => ({ message: 'error' }) }),
    async () => {
      throw new Error('offline');
    }
  ]) {
    assert.equal(
      await loadPublicUserMetric({
        endpoint: 'https://example.test/stats',
        fetcher,
        retryDelayMs: 0
      }),
      USER_COUNT_UNAVAILABLE_STATE
    );
  }
});

test('retries transient failures once and returns the recovered metric', async () => {
  let requests = 0;
  const result = await loadPublicUserMetric({
    endpoint: 'https://example.test/stats',
    retryDelayMs: 0,
    fetcher: async () => {
      requests += 1;
      return requests === 1
        ? { ok: false, status: 503 }
        : { ok: true, status: 200, json: async () => ({ metric: '4.3K+' }) };
    }
  });

  assert.equal(requests, 2);
  assert.deepEqual(result, { status: 'ready', metric: '4.3K+' });
});

test('does not retry client errors or malformed successful responses', async () => {
  for (const response of [
    { ok: false, status: 403 },
    { ok: true, status: 200, json: async () => ({ message: 'error' }) },
    {
      ok: true,
      status: 200,
      json: async () => {
        throw new SyntaxError('invalid json');
      }
    }
  ]) {
    let requests = 0;
    const result = await loadPublicUserMetric({
      endpoint: 'https://example.test/stats',
      retryDelayMs: 0,
      fetcher: async () => {
        requests += 1;
        return response;
      }
    });

    assert.equal(requests, 1);
    assert.equal(result, USER_COUNT_UNAVAILABLE_STATE);
  }
});

test('returns unavailable after both transient attempts fail', async () => {
  let requests = 0;
  const result = await loadPublicUserMetric({
    endpoint: 'https://example.test/stats',
    retryDelayMs: 0,
    fetcher: async () => {
      requests += 1;
      throw new Error('offline');
    }
  });

  assert.equal(requests, 2);
  assert.equal(result, USER_COUNT_UNAVAILABLE_STATE);
});

test('creates ready and neutral fallback presentations', () => {
  assert.deepEqual(
    createUserCountPresentation({ status: 'ready', metric: '4.3K+' }),
    {
      state: 'ready',
      metric: '4.3K+',
      label: 'People have joined',
      announcement: '4.3K+ people have joined Better Keep'
    }
  );
  assert.deepEqual(createUserCountPresentation(USER_COUNT_UNAVAILABLE_STATE), {
    state: 'unavailable',
    metric: null,
    label: 'Growing community',
    announcement: 'Better Keep has a growing community'
  });
});

test('aborts a stalled user-count request at the configured timeout', async () => {
  let abortedAttempts = 0;
  const result = await loadPublicUserMetric({
    endpoint: 'https://example.test/stats',
    timeoutMs: 5,
    retryDelayMs: 0,
    fetcher: (_url, { signal }) =>
      new Promise((_resolve, reject) => {
        signal.addEventListener(
          'abort',
          () => {
            abortedAttempts += 1;
            reject(new Error('aborted'));
          },
          { once: true }
        );
      })
  });
  assert.equal(abortedAttempts, 2);
  assert.equal(result, USER_COUNT_UNAVAILABLE_STATE);
});
