import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveAdminTotpChallenge } from '../src/lib/admin-mfa-flow.mjs';

test('a rejected TOTP code returns its error without discarding the challenge', async () => {
  const expected = Object.assign(new Error('Invalid code'), { code: 'auth/invalid-verification-code' });
  const resolver = {
    resolveSignIn: async () => {
      throw expected;
    }
  };

  const result = await resolveAdminTotpChallenge({
    assertionForSignIn: (hintUid, code) => ({ hintUid, code }),
    code: '123456',
    hintUid: 'totp-factor',
    resolver
  });

  assert.deepEqual(result, { ok: false, error: expected });
});

test('a valid TOTP code returns success so the caller can clear its resolver', async () => {
  const credential = { user: { uid: 'admin' } };
  const result = await resolveAdminTotpChallenge({
    assertionForSignIn: (hintUid, code) => ({ hintUid, code }),
    code: '654321',
    hintUid: 'totp-factor',
    resolver: { resolveSignIn: async () => credential }
  });

  assert.deepEqual(result, { ok: true, credential });
});
