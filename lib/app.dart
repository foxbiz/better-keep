import 'dart:async';

import 'package:better_keep/components/alarm_banner.dart';
import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/open_in_app_banner.dart';
import 'package:better_keep/components/session_invalid_banner.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/config.dart';
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
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/razorpay_web.dart'
    if (dart.library.io) 'package:better_keep/services/monetization/razorpay_stub.dart'
    as razorpay_platform;
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:better_keep/l10n/app_localizations.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  late ThemeData themeData;
  late final void Function(dynamic) _themeListener;
  late final void Function(dynamic) _localeListener;
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
    };
    AppState.subscribe("locale", _localeListener);

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Check for token revocation when app resumes from background
      AuthService.checkTokenRevocationOnResume();
      // Refresh subscription status when app comes to foreground
      // Also validate with backend to catch cancelled subscriptions
      if (AuthService.currentUser != null) {
        PlanService.instance.refreshSubscription(validateWithBackend: true);
        // On iOS, also restore purchases to pick up subscription changes
        // made in the App Store management page (cancel / re-subscribe).
        // restorePurchases sends a fresh receipt to the server which reads
        // the current auto_renew_status from Apple.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          unawaited(SubscriptionService.instance.restoreAndWaitForPurchases());
        }
      }
      // Check for pending intents (files opened via intent while app was in background)
      IntentHandlerService.instance.checkPendingIntents();
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
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
          Locale('ja'),
          Locale('ko'),
          Locale('id'),
          Locale('pt', 'BR'),
          Locale('zh'),
        ],
        locale: _locale,
        title: 'Better Keep',
        theme: themeData,
        builder: (context, child) {
          // Wrap with banners at the top of the app
          return Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (context) => Column(
                  children: [
                    // Show "Open in App" banner on web when native app is installed
                    const OpenInAppBanner(),
                    const AlarmBanner(),
                    const SessionInvalidBanner(),
                    Expanded(child: child ?? const SizedBox.shrink()),
                  ],
                ),
              ),
            ],
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
                  // Check E2EE status for pending approval, revoked, or still initializing
                  return ValueListenableBuilder<E2EEStatus>(
                    valueListenable: E2EEService.instance.status,
                    builder: (context, e2eeStatus, child) {
                      AppLogger.log('[Auth] E2EE status: $e2eeStatus');
                      if (e2eeStatus == E2EEStatus.pendingApproval ||
                          e2eeStatus == E2EEStatus.revoked) {
                        AppLogger.log('[Auth] Showing PendingApprovalPage');
                        return const PendingApprovalPage();
                      }
                      // Show account recovery page when no approved devices exist
                      if (e2eeStatus == E2EEStatus.needsRecovery) {
                        AppLogger.log('[Auth] Showing AccountRecoveryPage');
                        return const AccountRecoveryPage();
                      }
                      // Show loading while E2EE is still initializing (no cached status)
                      // Note: verifyingInBackground goes directly to Home (handled below)
                      if (e2eeStatus == E2EEStatus.notInitialized) {
                        AppLogger.log('[Auth] Showing E2EE loading screen');
                        return AuthScaffold(child: _E2EELoadingWidget());
                      }
                      // Handle error state - block access until encryption is available
                      if (e2eeStatus == E2EEStatus.error) {
                        return AuthScaffold(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 64,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(height: 24),
                              Text(
                                'Encryption Error',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Unable to initialize encryption. Your notes cannot be accessed without encryption.',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 32),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  E2EEService.instance.status.value =
                                      E2EEStatus.notInitialized;
                                  E2EEService.instance.resetInitialization();
                                  try {
                                    await E2EEService.instance.initialize();
                                  } catch (e) {
                                    AppLogger.error(
                                      '[Auth] E2EE retry failed from error screen',
                                      e,
                                    );
                                  }
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                              const SizedBox(height: 16),
                              TextButton.icon(
                                onPressed: () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      icon: const Icon(
                                        Icons.logout,
                                        color: Colors.orange,
                                        size: 32,
                                      ),
                                      title: const Text('Sign Out'),
                                      content: const Text(
                                        'Are you sure you want to sign out?\n\n'
                                        'You will need to sign in again to access your notes.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(true),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Colors.orange,
                                          ),
                                          child: const Text('Sign Out'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    try {
                                      await AuthService.signOut();
                                    } catch (e) {
                                      // Error is logged, sign out should still proceed
                                    }
                                  }
                                },
                                icon: const Icon(Icons.logout),
                                label: const Text('Sign Out'),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () {
                                  // Mark session as invalid to allow access to local notes
                                  AuthService.sessionInvalid.value = true;
                                },
                                child: const Text('Continue Offline'),
                              ),
                            ],
                          ),
                        );
                      }
                      // E2EE is ready, verifyingInBackground, or setup complete - show home
                      // verifyingInBackground allows immediate access while verification happens
                      AppLogger.log(
                        '[Auth] E2EE ready/verifying, showing Home',
                      );
                      return Home();
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
        E2EEService.instance.initialize();
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
    E2EEService.instance.status.value = E2EEStatus.notInitialized;
    E2EEService.instance.resetInitialization();

    try {
      await E2EEService.instance.initialize();
    } catch (e) {
      AppLogger.error('[Auth] E2EE retry failed from loading screen', e);
    }

    _scheduleAutoRetry();
  }

  Future<void> _signOutSafely() async {
    try {
      await AuthService.signOut();
    } catch (e) {
      AppLogger.error('[Auth] Sign out failed from loading screen', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Verifying Account',
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
        ValueListenableBuilder<String>(
          valueListenable: E2EEService.instance.statusMessage,
          builder: (context, message, child) {
            return Text(
              message.isNotEmpty ? message : "Setting up encryption...",
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
            'Taking longer than expected?',
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
                label: const Text('Retry'),
              ),
              const SizedBox(width: 16),
              TextButton.icon(
                onPressed: _signOutSafely,
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Sign Out'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              AuthService.sessionInvalid.value = true;
            },
            child: const Text('Continue Offline'),
          ),
        ],
      ],
    );
  }
}
