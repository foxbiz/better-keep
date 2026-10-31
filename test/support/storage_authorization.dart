import 'package:better_keep/services/external_sync/storage_authorization.dart';

class FakeStorageAuthorization extends StorageAuthorizationClient {
  Future<Map<String, dynamic>> Function()? consent;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>, String?)?
  refreshGrant;
  bool compatible = true;
  bool revoked = true;
  int refreshes = 0;
  int cancellations = 0;
  @override
  Future<PreparedStorageAuthorization> prepare(String provider) async =>
      StorageAuthorizationOperation(
        () => consent!(),
        onCancel: () async {
          cancellations++;
        },
      );
  @override
  Future<bool> supports(
    String provider,
    Map<String, dynamic> credentials,
  ) async => compatible;
  @override
  Future<Map<String, dynamic>> refresh(
    String provider,
    Map<String, dynamic> credentials, {
    String? rejectedToken,
    Map<String, dynamic>? exchangeContext,
  }) async {
    refreshes++;
    if (!compatible) storageConsentRequired();
    return refreshGrant == null
        ? credentials
        : refreshGrant!(credentials, rejectedToken);
  }

  @override
  Future<bool> revoke(
    String provider,
    Map<String, dynamic> credentials,
  ) async => revoked;
}
