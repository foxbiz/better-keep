// Native platforms use flutter_secure_storage.
Future<(int, String?)> readDeviceIdentity(String scope, String uid) =>
    throw UnsupportedError('Browser only');

Future<int> writeDeviceIdentity(
  String scope,
  String uid,
  String? identity, {
  required int? expectedRevision,
  required bool Function() isCurrent,
  void Function()? beforeClear,
  String? grantToActivate,
}) => throw UnsupportedError('Browser only');

class BrowserIdentityConflict implements Exception {
  const BrowserIdentityConflict();
}

String newOfflineGrantId() => throw UnsupportedError('Browser only');

enum OfflineGrantState { active, revoked, missing, unavailable }

OfflineGrantState offlineGrantState(String? id) =>
    throw UnsupportedError('Browser only');
void invalidateOfflineGrant(String id, {required bool revoked}) =>
    throw UnsupportedError('Browser only');
void retireOfflineGrant(String? id) => throw UnsupportedError('Browser only');
