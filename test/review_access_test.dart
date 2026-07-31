import 'package:better_keep/services/review_access.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reviewEmail = 'review@betterkeep.app';

  setUp(ReviewAccess.clear);
  tearDown(ReviewAccess.clear);

  group('ReviewAccess.hasRequiredAuthorization', () {
    test('accepts the exact review identity with the signed boolean claim', () {
      expect(
        ReviewAccess.hasRequiredAuthorization(
          email: reviewEmail,
          claims: const {'email': reviewEmail, 'appReview': true},
        ),
        isTrue,
      );
    });

    test('rejects the review email when the claim is missing', () {
      expect(
        ReviewAccess.hasRequiredAuthorization(
          email: reviewEmail,
          claims: const {'email': reviewEmail},
        ),
        isFalse,
      );
    });

    test('rejects a true-looking string claim', () {
      expect(
        ReviewAccess.hasRequiredAuthorization(
          email: reviewEmail,
          claims: const {'email': reviewEmail, 'appReview': 'true'},
        ),
        isFalse,
      );
    });

    test('rejects the claim on another authenticated email', () {
      expect(
        ReviewAccess.hasRequiredAuthorization(
          email: 'someone@example.com',
          claims: const {'email': 'someone@example.com', 'appReview': true},
        ),
        isFalse,
      );
    });

    test('rejects a token whose email does not match the Firebase user', () {
      expect(
        ReviewAccess.hasRequiredAuthorization(
          email: reviewEmail,
          claims: const {'email': 'someone@example.com', 'appReview': true},
        ),
        isFalse,
      );
    });
  });

  group('ReviewAuthorization', () {
    test('accepts an active signed Pro entitlement', () {
      final authorization = ReviewAuthorization.fromClaims(
        uid: 'review-uid',
        claims: {
          'plan': 'pro',
          'planExpiresAt': DateTime.utc(2035, 1, 1).millisecondsSinceEpoch,
        },
      );

      expect(authorization.hasActivePro(at: DateTime.utc(2030, 1, 1)), isTrue);
      expect(authorization.plan, 'pro');
      expect(authorization.planExpiresAt, DateTime.utc(2035, 1, 1));
    });

    test('rejects missing, malformed, and expired Pro entitlements', () {
      final at = DateTime.utc(2030, 1, 1);
      for (final claims in <Map<String, dynamic>>[
        const {},
        const {'plan': 'free', 'planExpiresAt': 4102444800000},
        const {'plan': 'PRO', 'planExpiresAt': 4102444800000},
        const {'plan': 'pro', 'planExpiresAt': '4102444800000'},
        {
          'plan': 'pro',
          'planExpiresAt': DateTime.utc(2029, 1, 1).millisecondsSinceEpoch,
        },
      ]) {
        final authorization = ReviewAuthorization.fromClaims(
          uid: 'review-uid',
          claims: claims,
        );
        expect(
          authorization.hasActivePro(at: at),
          isFalse,
          reason: claims.toString(),
        );
      }
    });
  });

  group('ReviewAccess token loading', () {
    test(
      'ordinary identities never request a token and clear stale state',
      () async {
        final reviewUser = _FakeUser(
          uid: 'review-uid',
          email: reviewEmail,
          loadToken: (_) async => _reviewToken(),
        );
        await ReviewAccess.authorize(reviewUser);

        var tokenRequests = 0;
        final ordinaryUser = _FakeUser(
          uid: 'ordinary-uid',
          email: 'ordinary@example.com',
          loadToken: (_) async {
            tokenRequests++;
            throw StateError('ordinary users must not load review claims');
          },
        );

        expect(await ReviewAccess.authorize(ordinaryUser), isFalse);
        expect(tokenRequests, 0);
        expect(ReviewAccess.authorizationFor(reviewUser), isNull);
      },
    );

    test('restored authorization uses the current cached token', () async {
      bool? forceRefresh;
      final user = _FakeUser(
        uid: 'review-uid',
        email: reviewEmail,
        loadToken: (force) async {
          forceRefresh = force;
          return _reviewToken();
        },
      );

      expect(await ReviewAccess.authorize(user), isTrue);
      expect(forceRefresh, isFalse);
      expect(ReviewAccess.authorizationFor(user)?.uid, 'review-uid');
    });

    test('explicit authorization refresh forces a new token', () async {
      bool? forceRefresh;
      final user = _FakeUser(
        uid: 'review-uid',
        email: reviewEmail,
        loadToken: (force) async {
          forceRefresh = force;
          return _reviewToken();
        },
      );

      expect(await ReviewAccess.refreshAuthorization(user), isTrue);
      expect(forceRefresh, isTrue);
    });

    test(
      'token failures propagate and retain verified authorization',
      () async {
        final authorizedUser = _FakeUser(
          uid: 'review-uid',
          email: reviewEmail,
          loadToken: (_) async => _reviewToken(),
        );
        await ReviewAccess.authorize(authorizedUser);

        final failingUser = _FakeUser(
          uid: 'review-uid',
          email: reviewEmail,
          loadToken: (_) async => throw StateError('offline'),
        );

        await expectLater(
          ReviewAccess.refreshAuthorization(failingUser),
          throwsStateError,
        );
        expect(ReviewAccess.authorizationFor(authorizedUser), isNotNull);
      },
    );

    test(
      'verified missing or false review claims clear authorization',
      () async {
        final authorizedUser = _FakeUser(
          uid: 'review-uid',
          email: reviewEmail,
          loadToken: (_) async => _reviewToken(),
        );
        await ReviewAccess.authorize(authorizedUser);

        for (final claims in <Map<String, dynamic>>[
          const {'email': reviewEmail},
          const {'email': reviewEmail, 'appReview': false},
        ]) {
          final unauthorizedUser = _FakeUser(
            uid: 'review-uid',
            email: reviewEmail,
            loadToken: (_) async => _FakeIdTokenResult(claims),
          );

          expect(await ReviewAccess.authorize(unauthorizedUser), isFalse);
          expect(ReviewAccess.authorizationFor(authorizedUser), isNull);
          await ReviewAccess.authorize(authorizedUser);
        }
      },
    );
  });

  group('ReviewAccess client capabilities', () {
    test('review identity detection is normalized and ordinary users pass', () {
      final reviewUser = _FakeUser(
        uid: 'review-uid',
        email: ' REVIEW@BETTERKEEP.APP ',
        loadToken: (_) async => _reviewToken(),
      );
      final ordinaryUser = _FakeUser(
        uid: 'ordinary-uid',
        email: 'ordinary@example.com',
        loadToken: (_) async => _reviewToken(),
      );

      expect(ReviewAccess.isReviewIdentity(reviewUser), isTrue);
      expect(ReviewAccess.isReviewIdentity(ordinaryUser), isFalse);
      expect(ReviewAccess.isCloudMutationBlockedFor(reviewUser), isTrue);
      expect(ReviewAccess.isCloudMutationBlockedFor(ordinaryUser), isFalse);
    });

    test('invalid review claims fail closed with a typed error', () {
      final reviewUser = _FakeUser(
        uid: 'review-uid',
        email: reviewEmail,
        loadToken: (_) async => _reviewToken(),
      );
      final ordinaryUser = _FakeUser(
        uid: 'ordinary-uid',
        email: 'ordinary@example.com',
        loadToken: (_) async => _reviewToken(),
      );

      expect(
        () => ReviewAccess.requireAuthorizedReviewIdentity(reviewUser, false),
        throwsA(isA<ReviewAuthorizationException>()),
      );
      expect(
        () => ReviewAccess.requireAuthorizedReviewIdentity(reviewUser, true),
        returnsNormally,
      );
      expect(
        () => ReviewAccess.requireAuthorizedReviewIdentity(ordinaryUser, false),
        returnsNormally,
      );
    });

    test('cloud mutation guard throws a typed review error', () {
      final reviewUser = _FakeUser(
        uid: 'review-uid',
        email: reviewEmail,
        loadToken: (_) async => _reviewToken(),
      );
      final ordinaryUser = _FakeUser(
        uid: 'ordinary-uid',
        email: 'ordinary@example.com',
        loadToken: (_) async => _reviewToken(),
      );

      expect(
        () => ReviewAccess.ensureCloudMutationAllowed(
          reviewUser,
          operation: 'Cloud sharing',
        ),
        throwsA(
          isA<ReviewCloudMutationBlocked>().having(
            (error) => error.operation,
            'operation',
            'Cloud sharing',
          ),
        ),
      );
      expect(
        () => ReviewAccess.ensureCloudMutationAllowed(
          ordinaryUser,
          operation: 'Cloud sharing',
        ),
        returnsNormally,
      );
    });

    test('cloud actions are hidden while local notes and sharing remain', () {
      final reviewUser = _FakeUser(
        uid: 'review-uid',
        email: reviewEmail,
        loadToken: (_) async => _reviewToken(),
      );
      final ordinaryUser = _FakeUser(
        uid: 'ordinary-uid',
        email: 'ordinary@example.com',
        loadToken: (_) async => _reviewToken(),
      );

      for (final capability in const [
        ReviewCapability.cloudMutation,
        ReviewCapability.cloudLinkSharing,
        ReviewCapability.accountManagement,
        ReviewCapability.accountRecovery,
      ]) {
        expect(
          ReviewAccess.allows(reviewUser, capability),
          isFalse,
          reason: capability.name,
        );
        expect(
          ReviewAccess.allows(ordinaryUser, capability),
          isTrue,
          reason: capability.name,
        );
      }

      for (final capability in const [
        ReviewCapability.localNotes,
        ReviewCapability.localSharing,
      ]) {
        expect(
          ReviewAccess.allows(reviewUser, capability),
          isTrue,
          reason: capability.name,
        );
      }
    });
  });
}

_FakeIdTokenResult _reviewToken() => const _FakeIdTokenResult({
  'email': 'review@betterkeep.app',
  'appReview': true,
  'plan': 'pro',
  'planExpiresAt': 4102444800000,
});

class _FakeUser implements User {
  const _FakeUser({
    required this.uid,
    required this.email,
    required this.loadToken,
  });

  @override
  final String uid;

  @override
  final String? email;

  final Future<IdTokenResult> Function(bool forceRefresh) loadToken;

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) =>
      loadToken(forceRefresh);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeIdTokenResult implements IdTokenResult {
  const _FakeIdTokenResult(this.claims);

  @override
  final Map<String, dynamic>? claims;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
