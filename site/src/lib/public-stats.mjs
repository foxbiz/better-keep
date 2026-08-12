export const USER_COUNT_LOADING_STATE = Object.freeze({
  status: 'loading',
  metric: null
});

export const USER_COUNT_UNAVAILABLE_STATE = Object.freeze({
  status: 'unavailable',
  metric: null
});

const USER_COUNT_UNAVAILABLE_PRESENTATION = Object.freeze({
  state: 'unavailable',
  metric: null,
  label: 'Growing community',
  announcement: 'Better Keep has a growing community'
});

const compactMetricPattern = /^\d+(?:\.\d)?[KM]\+$/;
const roundedCountPattern = /^(\d+)(\+)?$/;

export function compactUserCount(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toUpperCase();
  if (compactMetricPattern.test(normalized)) return normalized;

  const match = normalized.match(roundedCountPattern);
  if (!match) return null;
  const count = Number.parseInt(match[1], 10);
  if (!Number.isSafeInteger(count) || count <= 0) return null;

  const plus = match[2] || '';
  if (count < 1000) return `${count}${plus}`;

  const divisor = count >= 1_000_000 ? 1_000_000 : 1000;
  const unit = divisor === 1_000_000 ? 'M' : 'K';
  const compact = Math.floor((count / divisor) * 10) / 10;
  const formatted = Number.isInteger(compact)
    ? compact.toFixed(0)
    : compact.toFixed(1);
  return `${formatted}${unit}${plus}`;
}

export function resolvePublicUserMetric(payload) {
  if (!payload || typeof payload !== 'object') return null;
  return compactUserCount(payload.metric) || compactUserCount(payload.message);
}

export function createUserCountPresentation(result) {
  const metric =
    result?.status === 'ready' ? compactUserCount(result.metric) : null;
  if (!metric) return USER_COUNT_UNAVAILABLE_PRESENTATION;

  return {
    state: 'ready',
    metric,
    label: 'People have joined',
    announcement: `${metric} people have joined Better Keep`
  };
}

async function loadPublicUserMetricAttempt({
  endpoint,
  fetcher,
  timeoutMs,
  AbortControllerClass
}) {
  const controller = new AbortControllerClass();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  try {
    let response;
    try {
      response = await fetcher(endpoint, {
        headers: { Accept: 'application/json' },
        signal: controller.signal
      });
    } catch {
      return { result: USER_COUNT_UNAVAILABLE_STATE, retryable: true };
    }

    if (!response?.ok) {
      const retryable =
        Number.isInteger(response?.status) && response.status >= 500;
      return { result: USER_COUNT_UNAVAILABLE_STATE, retryable };
    }

    let payload;
    try {
      payload = await response.json();
    } catch {
      return {
        result: USER_COUNT_UNAVAILABLE_STATE,
        retryable: controller.signal.aborted
      };
    }

    const metric = resolvePublicUserMetric(payload);
    return metric
      ? { result: { status: 'ready', metric }, retryable: false }
      : { result: USER_COUNT_UNAVAILABLE_STATE, retryable: false };
  } finally {
    clearTimeout(timeoutId);
  }
}

export async function loadPublicUserMetric({
  endpoint,
  fetcher = globalThis.fetch,
  timeoutMs = 3000,
  maxAttempts = 2,
  retryDelayMs = 250,
  AbortControllerClass = globalThis.AbortController
}) {
  if (
    typeof endpoint !== 'string' ||
    !endpoint.startsWith('https://') ||
    typeof fetcher !== 'function' ||
    typeof AbortControllerClass !== 'function'
  ) {
    return USER_COUNT_UNAVAILABLE_STATE;
  }

  const attemptLimit =
    Number.isInteger(maxAttempts) && maxAttempts > 0 ? maxAttempts : 1;

  for (let attempt = 1; attempt <= attemptLimit; attempt += 1) {
    const { result, retryable } = await loadPublicUserMetricAttempt({
      endpoint,
      fetcher,
      timeoutMs,
      AbortControllerClass
    });
    if (!retryable || attempt === attemptLimit) return result;

    if (retryDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }

  return USER_COUNT_UNAVAILABLE_STATE;
}
