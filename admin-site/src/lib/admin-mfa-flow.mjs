/**
 * Resolves one TOTP challenge without discarding the resolver after a rejected
 * code. The caller clears its resolver only when this returns success.
 */
export async function resolveAdminTotpChallenge({
  assertionForSignIn,
  code,
  hintUid,
  resolver
}) {
  try {
    const assertion = assertionForSignIn(hintUid, code);
    const credential = await resolver.resolveSignIn(assertion);
    return { ok: true, credential };
  } catch (error) {
    return { ok: false, error };
  }
}
