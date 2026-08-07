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
