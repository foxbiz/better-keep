import 'package:better_keep/services/external_sync/storage_authorization_native.dart';
import 'package:better_keep/services/external_sync/storage_authorization_types.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

class AuthorizationSdk extends GoogleSignInPlatform {
  final calls = <String>[];
  AuthorizationRequestDetails? request;
  ClientAuthorizationTokenData? result = const ClientAuthorizationTokenData(
    accessToken: 'local-token',
  );
  @override
  Future<void> init(InitParameters params) async {
    calls.add('init');
  }

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    calls.add('authorize');
    request = params.request;
    return result;
  }

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {
    calls.add('clear:${params.accessToken}');
  }

  // Any authentication, sign-out, or server-code request is a test failure.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected SDK method: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android uses authorization only and pins silent renewal to the Drive owner', () async {
    final old = GoogleSignInPlatform.instance;
    final sdk = AuthorizationSdk();
    GoogleSignInPlatform.instance = sdk;
    addTearDown(() => GoogleSignInPlatform.instance = old);
    final initial = await androidGoogleGrant(prompt: true);
    expect(initial['grant'], 'google_device');
    expect(initial.containsKey('refreshToken'), isFalse);
    expect(sdk.request!.scopes, googleStorageScopes);
    expect(sdk.request!.promptIfUnauthorized, isTrue);
    sdk.calls.clear();
    await androidGoogleGrant(
      prompt: false,
      credentials: {
        'accountId': 'owner-id',
        'accountLabel': 'owner@example.test',
      },
      rejectedToken: 'expired',
    );
    expect(sdk.calls, ['clear:expired', 'authorize']);
    expect(sdk.request!.userId, 'owner-id');
    expect(sdk.request!.email, 'owner@example.test');
    expect(sdk.request!.promptIfUnauthorized, isFalse);
    sdk.result = null;
    await expectLater(
      androidGoogleGrant(prompt: false),
      throwsA(isA<SyncProviderFailure>()),
    );
  });
}
