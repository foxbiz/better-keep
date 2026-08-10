import assert from 'node:assert/strict';
import test from 'node:test';
import {
  clearAdminCredentialFields,
  createAdminLoginGate,
  handleAdminEntryFailure,
  sanitizedAdminLocation,
  shouldSignOutAfterAdminError
} from '../src/lib/admin-login-safety.mjs';

test('removes legacy credentials without discarding safe URL state', () => {
  assert.equal(
    sanitizedAdminLocation(
      'https://admin.betterkeep.app/?email=admin%40example.com&debug=1&password=secret#login'
    ),
    '/?debug=1#login'
  );
  assert.equal(sanitizedAdminLocation('https://admin.betterkeep.app/?debug=1'), null);
});

test('login remains fail-closed until Firebase initialization succeeds', () => {
  const submitButton = { disabled: false };
  const message = { textContent: '' };
  const gate = createAdminLoginGate({ submitButton, message });
  let prevented = false;
  const event = { preventDefault: () => { prevented = true; } };

  assert.equal(submitButton.disabled, true);
  assert.equal(gate.accept(event), false);
  assert.equal(prevented, true, 'native form navigation must always be prevented');

  gate.markUnavailable('Firebase configuration is unavailable.');
  assert.equal(submitButton.disabled, true);
  assert.equal(message.textContent, 'Firebase configuration is unavailable.');

  prevented = false;
  gate.markReady();
  assert.equal(submitButton.disabled, false);
  assert.equal(gate.accept(event), true);
  assert.equal(prevented, true, 'ready submissions must still avoid native navigation');
});

test('authorization and stale-session failures require sign-out', () => {
  assert.equal(
    shouldSignOutAfterAdminError({ code: 'functions/unauthenticated' }),
    true
  );
  assert.equal(
    shouldSignOutAfterAdminError({ code: 'functions/permission-denied' }),
    true
  );
  assert.equal(
    shouldSignOutAfterAdminError({
      code: 'functions/failed-precondition',
      message: 'Recent administrator authentication is required.'
    }),
    true
  );
  assert.equal(
    shouldSignOutAfterAdminError({ code: 'functions/unavailable' }),
    false
  );
  assert.equal(
    shouldSignOutAfterAdminError({ code: 'auth/user-token-expired' }),
    true
  );
});

test('data failures preserve the authenticated dashboard session', async () => {
  const calls = [];
  const result = await handleAdminEntryFailure({
    error: { code: 'admin/overview-contract' },
    signOut: async () => calls.push('sign-out'),
    showLogin: () => calls.push('login'),
    showDashboardError: () => calls.push('dashboard-error')
  });

  assert.equal(result, 'preserved');
  assert.deepEqual(calls, ['dashboard-error']);
});

test('authorization failures sign out before returning to login', async () => {
  const calls = [];
  const result = await handleAdminEntryFailure({
    error: { code: 'functions/permission-denied' },
    signOut: async () => calls.push('sign-out'),
    showLogin: () => calls.push('login'),
    showDashboardError: () => calls.push('dashboard-error')
  });

  assert.equal(result, 'signed-out');
  assert.deepEqual(calls, ['sign-out', 'login']);
});

test('returning to sign-in clears credentials and enrollment secrets', () => {
  const email = { value: 'admin@example.com' };
  const password = { value: 'secret' };
  const mfaCode = { value: '123456' };
  const enrollmentCode = { value: '654321' };
  const totpSecret = { textContent: 'TOTPSECRET' };
  const removed = [];
  const totpQr = { removeAttribute: (name) => removed.push(name) };

  clearAdminCredentialFields({
    email,
    password,
    mfaCode,
    enrollmentCode,
    totpSecret,
    totpQr
  });

  assert.deepEqual(
    [email.value, password.value, mfaCode.value, enrollmentCode.value],
    ['', '', '', '']
  );
  assert.equal(totpSecret.textContent, '');
  assert.deepEqual(removed, ['src']);
});
