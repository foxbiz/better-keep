export const USER_COUNT_LOADING_STATE = Object.freeze({
  status: 'loading',
  metric: null
});

export const USER_COUNT_UNAVAILABLE_STATE = Object.freeze({
  status: 'unavailable',
  metric: null
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

export async function loadPublicUserMetric({
  endpoint,
  fetcher = globalThis.fetch,
  timeoutMs = 5000,
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

  const controller = new AbortControllerClass();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetcher(endpoint, {
      headers: { Accept: 'application/json' },
      signal: controller.signal
    });
    if (!response?.ok) return USER_COUNT_UNAVAILABLE_STATE;

    const metric = resolvePublicUserMetric(await response.json());
    return metric
      ? { status: 'ready', metric }
      : USER_COUNT_UNAVAILABLE_STATE;
  } catch {
    return USER_COUNT_UNAVAILABLE_STATE;
  } finally {
    clearTimeout(timeoutId);
  }
}
