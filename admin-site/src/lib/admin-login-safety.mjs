const CREDENTIAL_QUERY_PARAMETERS = ['email', 'password'];

/**
 * Returns a same-origin path without credential query parameters, or null when
 * the URL is already safe. Other query parameters and the fragment are kept.
 */
export function sanitizedAdminLocation(href) {
  const url = new URL(href);
  let changed = false;
  for (const parameter of CREDENTIAL_QUERY_PARAMETERS) {
    if (url.searchParams.has(parameter)) {
      url.searchParams.delete(parameter);
      changed = true;
    }
  }
  return changed ? `${url.pathname}${url.search}${url.hash}` : null;
}

/**
 * Authorization failures are fail-closed. This includes stale authentication,
 * missing/revoked credentials, and server-side administrator policy rejection.
 */
export function shouldSignOutAfterAdminError(error) {
  const candidate = error ?? {};
  const code = typeof candidate.code === 'string'
    ? candidate.code.replace(/^functions\//, '')
    : '';
  if (code === 'unauthenticated' || code === 'permission-denied') return true;
  if (
    code === 'auth/invalid-user-token' ||
    code === 'auth/user-token-expired' ||
    code === 'auth/user-disabled'
  ) return true;
  return code === 'failed-precondition' &&
    /recent administrator authentication/i.test(candidate.message ?? '');
}

/**
 * Keeps authenticated administrators on the dashboard for transient data or
 * rendering failures, while authorization and session failures remain closed.
 */
export async function handleAdminEntryFailure({
  error,
  signOut,
  showLogin,
  showDashboardError
}) {
  if (!shouldSignOutAfterAdminError(error)) {
    showDashboardError(error);
    return 'preserved';
  }
  await signOut();
  showLogin(error);
  return 'signed-out';
}

/** Removes credentials and enrollment secrets before returning to sign-in. */
export function clearAdminCredentialFields({
  email,
  password,
  mfaCode,
  enrollmentCode,
  totpSecret,
  totpQr
}) {
  for (const field of [email, password, mfaCode, enrollmentCode]) field.value = '';
  totpSecret.textContent = '';
  totpQr.removeAttribute('src');
}

/**
 * Prevents native form navigation from the moment the admin module starts and
 * exposes an explicit readiness gate for Firebase initialization.
 */
export function createAdminLoginGate({ submitButton, message }) {
  let ready = false;
  submitButton.disabled = true;

  return {
    accept(event) {
      event.preventDefault();
      return ready;
    },
    markReady() {
      ready = true;
      submitButton.disabled = false;
      message.textContent = '';
    },
    markUnavailable(reason) {
      ready = false;
      submitButton.disabled = true;
      message.textContent = reason;
    }
  };
}
