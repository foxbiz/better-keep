// Native sign-outs are already serialized by AuthService in this isolate.
Future<bool> withSignOutLock(
  String scope,
  Future<void> Function() action,
) async {
  await action();
  return true;
}

Future<void> refreshAfterExternalSignOut(String scope) =>
    throw UnsupportedError('Only browsers share sign-out between windows');
