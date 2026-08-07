const SHARE_PATH_PATTERN = /^\/s\/([A-Za-z0-9]{1,128})\/?$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/_-]*={0,2}$/;

export const SHARE_STATES = Object.freeze([
  'loading',
  'request',
  'pending',
  'content',
  'expired',
  'revoked',
  'denied',
  'notFound',
  'error'
]);

export function parseShareLocation(location) {
  const match = location.pathname.match(SHARE_PATH_PATTERN);
  const fragment = location.hash.startsWith('#')
    ? location.hash.slice(1)
    : location.hash;

  return {
    shareId: match?.[1] ?? null,
    shareKey: fragment || null
  };
}

export function decodeBase64(value, expectedLength) {
  if (!value || !BASE64_PATTERN.test(value)) {
    throw new Error('Invalid base64 value');
  }

  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const unpadded = normalized.replace(/=+$/, '');
  const padded = unpadded.padEnd(Math.ceil(unpadded.length / 4) * 4, '=');
  let decoded;
  try {
    decoded = atob(padded);
  } catch {
    throw new Error('Invalid base64 value');
  }

  const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  if (expectedLength !== undefined && bytes.length !== expectedLength) {
    throw new Error(`Expected ${expectedLength} decoded bytes`);
  }
  return bytes;
}

function requireCrypto(cryptoProvider) {
  if (!cryptoProvider?.subtle) {
    throw new Error('Web Crypto is unavailable');
  }
  return cryptoProvider;
}

async function importShareKey(keyBase64, cryptoProvider) {
  const crypto = requireCrypto(cryptoProvider);
  return crypto.subtle.importKey(
    'raw',
    decodeBase64(keyBase64, 32),
    { name: 'AES-GCM' },
    false,
    ['decrypt']
  );
}

export async function decryptShareText(
  encryptedBase64,
  nonceBase64,
  keyBase64,
  cryptoProvider = globalThis.crypto
) {
  const crypto = requireCrypto(cryptoProvider);
  const key = await importShareKey(keyBase64, crypto);
  const nonce = decodeBase64(nonceBase64, 12);
  const encrypted = decodeBase64(encryptedBase64);
  if (encrypted.length < 17) throw new Error('Encrypted content is malformed');

  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce },
    key,
    encrypted
  );
  return new TextDecoder('utf-8', { fatal: true }).decode(decrypted);
}

export async function decryptShareBytes(
  encryptedBytes,
  keyBase64,
  cryptoProvider = globalThis.crypto
) {
  const crypto = requireCrypto(cryptoProvider);
  const bytes =
    encryptedBytes instanceof Uint8Array
      ? encryptedBytes
      : new Uint8Array(encryptedBytes);
  if (bytes.length < 29) throw new Error('Encrypted attachment is malformed');

  const key = await importShareKey(keyBase64, crypto);
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: bytes.slice(0, 12) },
      key,
      bytes.slice(12)
    )
  );
}

function asDate(value) {
  if (value instanceof Date) return value;
  if (value && typeof value.toDate === 'function') return value.toDate();
  if (typeof value === 'string' || typeof value === 'number') {
    return new Date(value);
  }
  return new Date(Number.NaN);
}

export function classifyShareRecord(record, now = new Date()) {
  if (!record || typeof record !== 'object') return 'invalid';
  if (record.status === 'revoked') return 'revoked';
  if (record.status === 'expired') return 'expired';
  if (record.status !== 'active') return 'invalid';

  const expiresAt = asDate(record.expires_at);
  if (Number.isNaN(expiresAt.getTime())) return 'invalid';
  return now > expiresAt ? 'expired' : 'active';
}

export function classifyRequestRecord(record) {
  if (record === null) return 'missing';
  if (!record || typeof record !== 'object') return 'invalid';
  if (record.status === 'approved') return 'approved';
  if (record.status === 'denied') return 'denied';
  if (record.status === 'pending') return 'pending';
  return 'invalid';
}

export function detectPlatform(userAgent) {
  const value = userAgent.toLowerCase();
  if (value.includes('android')) return 'android';
  if (value.includes('iphone') || value.includes('ipad')) return 'ios';
  if (value.includes('mac')) return 'macos';
  if (value.includes('windows')) return 'windows';
  if (value.includes('linux')) return 'linux';
  return 'web';
}

export function isSafeAttachmentPath(path) {
  return (
    typeof path === 'string' &&
    /^shares\/[A-Za-z0-9_-]+\/[A-Za-z0-9]+\/attachments\/[A-Za-z0-9._-]+$/.test(
      path
    )
  );
}

export function getLocalPreviewState(location) {
  if (!['localhost', '127.0.0.1'].includes(location.hostname)) return null;
  const state = new URLSearchParams(location.search).get('share-state');
  return SHARE_STATES.includes(state) ? state : null;
}

export function createByteBudget(maxBytes, { onExceeded } = {}) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new TypeError('Byte budget must be a non-negative safe integer');
  }
  let usedBytes = 0;
  let exceeded = false;

  return Object.freeze({
    get exceeded() {
      return exceeded;
    },
    get remainingBytes() {
      return maxBytes - usedBytes;
    },
    get usedBytes() {
      return usedBytes;
    },
    consume(byteLength) {
      if (!Number.isSafeInteger(byteLength) || byteLength < 0) {
        throw new TypeError('Consumed bytes must be a non-negative safe integer');
      }
      if (exceeded || byteLength > maxBytes - usedBytes) {
        if (!exceeded) {
          exceeded = true;
          onExceeded?.();
        }
        throw new Error('Shared-note attachment budget exceeded');
      }
      usedBytes += byteLength;
    }
  });
}

function declaredContentLength(response) {
  const value = response.headers?.get?.('content-length');
  if (value === null || value === undefined) return null;
  if (!/^\d+$/.test(value)) {
    throw new Error('Attachment Content-Length is invalid');
  }
  const length = Number(value);
  if (!Number.isSafeInteger(length)) {
    throw new Error('Attachment Content-Length is invalid');
  }
  return length;
}

async function cancelResponseBody(response) {
  try {
    await response.body?.cancel?.();
  } catch {
    // The request may already have been aborted by the aggregate budget.
  }
}

export async function readResponseBytesWithLimit(
  response,
  { maxBytes, budget }
) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new TypeError('Attachment limit must be a non-negative safe integer');
  }
  const declaredLength = declaredContentLength(response);
  if (declaredLength !== null && declaredLength > maxBytes) {
    await cancelResponseBody(response);
    throw new Error('Attachment is too large');
  }
  if (
    declaredLength !== null &&
    budget &&
    declaredLength > budget.remainingBytes
  ) {
    await cancelResponseBody(response);
    budget.consume(declaredLength);
  }

  const reader = response.body?.getReader?.();
  if (!reader) {
    throw new Error('Streaming attachment downloads are unavailable');
  }

  const chunks = [];
  let received = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      if (chunk.byteLength > maxBytes - received) {
        await reader.cancel('Attachment is too large');
        throw new Error('Attachment is too large');
      }
      budget?.consume(chunk.byteLength);
      received += chunk.byteLength;
      chunks.push(chunk);
    }
  } catch (error) {
    try {
      await reader.cancel(error);
    } catch {
      // Ignore cancellation races with AbortController.
    }
    throw error;
  } finally {
    reader.releaseLock?.();
  }

  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export async function mapWithConcurrency(items, concurrency, worker) {
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    throw new TypeError('Concurrency must be a positive integer');
  }
  const results = new Array(items.length);
  let nextIndex = 0;

  const runWorker = async () => {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      results[index] = await worker(items[index], index);
    }
  };

  await Promise.all(
    Array.from(
      { length: Math.min(concurrency, items.length) },
      () => runWorker()
    )
  );
  return results;
}

export function shouldObserveShareRequest(state) {
  return state === 'pending';
}

export async function loadShareRequestState({ load, handle, watch }) {
  if (
    typeof load !== 'function' ||
    typeof handle !== 'function' ||
    typeof watch !== 'function'
  ) {
    throw new TypeError('Share request handlers must be functions');
  }

  const state = await handle(await load());
  if (shouldObserveShareRequest(state)) watch();
  return state;
}

export function createSingleFlight(operation) {
  if (typeof operation !== 'function') {
    throw new TypeError('Single-flight operation must be a function');
  }

  let result;
  return (...args) => {
    result ??= Promise.resolve().then(() => operation(...args));
    return result;
  };
}
