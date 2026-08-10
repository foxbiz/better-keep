import 'dart:async';

import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/open_in_app_banner.dart';
import 'package:better_keep/components/post_sign_in_recovery_view.dart';
import 'package:better_keep/components/session_invalid_banner.dart';
import 'package:better_keep/components/firebase_environment_banner.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/pages/account_recovery_page.dart';
import 'package:better_keep/pages/email_verification_page.dart';
import 'package:better_keep/pages/home/home.dart';
import 'package:better_keep/pages/login_page.dart';
import 'package:better_keep/pages/pending_approval_page.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/utils/quill_image_utils.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/intent_handler_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/monetization/razorpay_web.dart'
    if (dart.library.io) 'package:better_keep/services/monetization/razorpay_stub.dart'
    as razorpay_platform;
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/services/motion_preferences.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> _retryPostSignInSafely(String source) async {
  try {
    await AuthService.retryPostSignInInitialization();
  } catch (error, stackTrace) {
    await AppLogger.error(
      '[Auth] Authenticated startup retry failed from $source',
      error,
      stackTrace,
    );
  }
}

Future<void> _safeAuthSignOut(String source) async {
  try {
    await AuthService.signOut();
  } catch (error, stackTrace) {
    await AppLogger.error(
      '[Auth] Sign out failed from $source',
      error,
      stackTrace,
    );
  }
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  late ThemeData themeData;
  late final void Function(dynamic) _themeListener;
  late final void Function(dynamic) _localeListener;
  late final void Function(dynamic) _morningTimeListener;
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    themeData = AppState.theme;
    _locale = AppState.locale;

    // Update web theme colors on initial load
    if (kIsWeb) {
      AppInstallService.instance.updateColorsFromTheme(themeData);
    }

    _themeListener = (value) {
      final newTheme = value as ThemeData;
      setState(() {
        themeData = newTheme;
      });
      // Update web theme colors when theme changes
      if (kIsWeb) {
        AppInstallService.instance.updateColorsFromTheme(newTheme);
      }
    };
    AppState.subscribe("theme", _themeListener);

    _localeListener = (value) {
      setState(() {
        _locale = value as Locale?;
      });
      unawaited(ReminderCoordinator.instance.reconcileAll());
    };
    AppState.subscribe("locale", _localeListener);

    _morningTimeListener = (_) {
      unawaited(ReminderCoordinator.instance.reconcileAll());
    };
    AppState.subscribe("morning_time", _morningTimeListener);

    // Set navigator key for Razorpay dialogs on desktop
    if (isDesktop) {
      razorpay_platform.setNavigatorKey(AppState.navigatorKey);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppState.unsubscribe("theme", _themeListener);
    AppState.unsubscribe("locale", _localeListener);
    AppState.unsubscribe("morning_time", _morningTimeListener);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Check for token revocation when app resumes from background
      AuthService.checkTokenRevocationOnResume();
      // Refresh subscription status when app comes to foreground
      // Also validate with backend to catch cancelled subscriptions
      final currentUser = AuthService.currentUser;
      if (currentUser != null) {
        PlanService.instance.refreshSubscription(validateWithBackend: true);
        // On iOS, also restore purchases to pick up subscription changes
        // made in the App Store management page (cancel / re-subscribe).
        // restorePurchases sends a fresh receipt to the server which reads
        // the current auto_renew_status from Apple.
        if (!ReviewAccess.isAuthorizedSessionFor(currentUser) &&
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.iOS) {
          unawaited(SubscriptionService.instance.restoreAndWaitForPurchases());
        }
      }
      // Check for pending intents (files opened via intent while app was in background)
      IntentHandlerService.instance.checkPendingIntents();
      unawaited(ReminderCoordinator.instance.onAppResumed());
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    SketchPage.clearBackgroundImageCache();
    QuillImageCache.instance.clear();
    NoteCard.clearImageCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  void didChangePlatformBrightness() {
    // Handle system theme changes
    if (AppState.followSystemTheme) {
      final brightness = View.of(context).platformDispatcher.platformBrightness;
      AppState.applySystemBrightness(brightness);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLogger.log('[App] Building App widget');
    final isDark = themeData.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: AppState.navigatorKey,
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        locale: _locale,
        onGenerateTitle: (context) => context.l10n.appTitle,
        theme: themeData,
        builder: (context, child) {
          // Keep MediaQuery consumers, such as animated images, aligned with
          // the binding-level policy used by AnimationController.
          return MotionMediaQuery(
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) =>
                      _BannerLayout(child: child ?? const SizedBox.shrink()),
                ),
              ],
            ),
          );
        },
        home: ValueListenableBuilder<bool>(
          valueListenable: AuthService.sessionInvalid,
          builder: (context, isSessionInvalid, child) {
            // If session is invalid, show home with warning banner
            // This allows user to access local notes even when auth fails
            if (isSessionInvalid) {
              AppLogger.log(
                '[Auth] Session invalid, showing Home with warning banner',
              );
              return Home();
            }
            return StreamBuilder<User?>(
              stream: AuthService.userStream,
              builder: (context, snapshot) {
                AppLogger.log(
                  '[Auth] ConnectionState: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, user: ${snapshot.data?.email}',
                );
                if (snapshot.connectionState == ConnectionState.waiting) {
                  AppLogger.log('[Auth] Showing waiting screen...');
                  return AuthScaffold(child: SizedBox.shrink());
                }
                if (snapshot.hasData) {
                  final user = snapshot.data!;
                  AppLogger.log('[Auth] User is logged in: ${user.email}');

                  // Check if email verification is required for email/password users
                  // OAuth users (Google, Facebook, etc.) don't need email verification
                  final hasPasswordProvider = user.providerData.any(
                    (info) => info.providerId == 'password',
                  );
                  final hasOAuthProvider = user.providerData.any(
                    (info) => info.providerId != 'password',
                  );

                  // Only require email verification for pure email/password users
                  // (not for users who also have OAuth providers linked)
                  if (hasPasswordProvider &&
                      !hasOAuthProvider &&
                      !user.emailVerified) {
                    AppLogger.log(
                      '[Auth] Email not verified, showing EmailVerificationPage',
                    );
                    return const EmailVerificationPage();
                  }

                  AppLogger.log(
                    '[Auth] Email verified or OAuth user, checking E2EE status...',
                  );
                  return ValueListenableBuilder<PostSignInState>(
                    valueListenable: AuthService.postSignInState,
                    builder: (context, postSignInState, child) {
                      return ValueListenableBuilder<E2EEStatus>(
                        valueListenable: E2EEService.instance.status,
                        builder: (context, e2eeStatus, child) {
                          AppLogger.log('[Auth] E2EE status: $e2eeStatus');
                          final route = resolveAuthenticatedStartupRoute(
                            postSignInState: postSignInState,
                            e2eeStatus: e2eeStatus,
                          );

                          return switch (route) {
                            AuthenticatedStartupRoute.loading =>
                              const AuthScaffold(child: _E2EELoadingWidget()),
                            AuthenticatedStartupRoute.pendingApproval =>
                              const PendingApprovalPage(),
                            AuthenticatedStartupRoute.accountRecovery =>
                              const AccountRecoveryPage(),
                            AuthenticatedStartupRoute.recovery => AuthScaffold(
                              child: PostSignInRecoveryView(
                                onRetry: () => _retryPostSignInSafely(
                                  'authenticated startup screen',
                                ),
                                onContinueOffline: AuthService
                                    .continueOfflineAfterInitializationFailure,
                                onSignOut: () => _safeAuthSignOut(
                                  'authenticated startup screen',
                                ),
                              ),
                            ),
                            AuthenticatedStartupRoute.home => Home(),
                          };
                        },
                      );
                    },
                  );
                }
                AppLogger.log('[Auth] No user, showing LoginPage');
                return const LoginPage();
              },
            );
          },
        ),
      ),
    );
  }
}

/// E2EE loading widget with timeout and retry options
class _E2EELoadingWidget extends StatefulWidget {
  const _E2EELoadingWidget();

  @override
  State<_E2EELoadingWidget> createState() => _E2EELoadingWidgetState();
}

class _E2EELoadingWidgetState extends State<_E2EELoadingWidget> {
  bool _showTimeoutOptions = false;
  int _retryCount = 0;
  Timer? _autoRetryTimer;
  Timer? _showOptionsTimer;
  static const _autoRetryTimeout = Duration(seconds: 5);
  static const _showOptionsTimeout = Duration(seconds: 6);
  static const _maxAutoRetries = 1;

  @override
  void initState() {
    super.initState();
    // Start auto-retry timer - if still stuck on notInitialized after timeout,
    // automatically trigger initialize() to recover from race conditions
    _scheduleAutoRetry();
  }

  @override
  void dispose() {
    _autoRetryTimer?.cancel();
    _showOptionsTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoRetry() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = Timer(_autoRetryTimeout, () {
      if (!mounted) return;
      if (E2EEService.instance.status.value != E2EEStatus.notInitialized) {
        return;
      }

      if (_retryCount < _maxAutoRetries) {
        _retryCount++;
        AppLogger.log(
          '[Auth] E2EE init timeout, auto-retrying (attempt $_retryCount/$_maxAutoRetries)',
        );
        unawaited(_retryPostSignInSafely('encryption timeout'));
        // Schedule next auto-retry
        _scheduleAutoRetry();
      } else {
        // Max retries exhausted, transition to error state
        AppLogger.log(
          '[Auth] E2EE init failed after $_maxAutoRetries auto-retries, showing error',
        );
        E2EEService.instance.status.value = E2EEStatus.error;
      }
    });

    // Also show manual retry options after a longer timeout (only once)
    _showOptionsTimer ??= Timer(_showOptionsTimeout, () {
      if (mounted &&
          E2EEService.instance.status.value == E2EEStatus.notInitialized) {
        setState(() => _showTimeoutOptions = true);
      }
    });
  }

  Future<void> _retryInitialization() async {
    setState(() => _showTimeoutOptions = false);
    _retryCount = 0;
    _showOptionsTimer?.cancel();
    _showOptionsTimer = null;
    await _retryPostSignInSafely('encryption loading screen');

    _scheduleAutoRetry();
  }

  Future<void> _signOutSafely() async {
    await _safeAuthSignOut('encryption loading screen');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          context.l10n.checkingAccountStatus,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              minHeight: 6,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(height: 24),
        ValueListenableBuilder<ProtectionProgress?>(
          valueListenable: E2EEService.instance.statusProgress,
          builder: (context, progress, child) {
            return Text(
              (progress ?? ProtectionProgress.gettingReady).localized(
                context.l10n,
              ),
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            );
          },
        ),
        if (_showTimeoutOptions) ...[
          const SizedBox(height: 32),
          Text(
            context.l10n.takingTooLongTryAgain,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _retryInitialization,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.retry),
              ),
              const SizedBox(width: 16),
              TextButton.icon(
                onPressed: _signOutSafely,
                icon: const Icon(Icons.logout, size: 18),
                label: Text(context.l10n.signOut),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: AuthService.continueOfflineAfterInitializationFailure,
            child: Text(context.l10n.continueOffline),
          ),
        ],
      ],
    );
  }
}

/// Lays out banners above the app content.
///
/// When any banner is visible, it already handles the top safe area (status bar).
/// To avoid double-counting (the app's Scaffold/AppBar also adds safe area padding),
/// this widget removes the top MediaQuery padding from the app child when a banner
/// is shown.
class _BannerLayout extends StatelessWidget {
  final Widget child;

  const _BannerLayout({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AuthService.sessionInvalid,
        SessionInvalidBanner.isDismissed,
        FirebaseBackend.configuration,
      ]),
      builder: (context, _) {
        final hasEnvironmentBanner =
            kDebugMode && FirebaseBackend.configuration.value != null;
        final hasSessionBanner =
            AuthService.sessionInvalid.value &&
            !SessionInvalidBanner.isDismissed.value;
        final hasBanner = hasEnvironmentBanner || hasSessionBanner;

        final appChild = hasBanner
            ? MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: child,
              )
            : child;

        return Column(
          children: [
            const FirebaseEnvironmentBanner(),
            MediaQuery.removePadding(
              context: context,
              removeTop: hasEnvironmentBanner,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [OpenInAppBanner(), SessionInvalidBanner()],
              ),
            ),
            Expanded(child: appChild),
          ],
        );
      },
    );
  }
}
