import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@immutable
class FirebaseEnvironmentStatus {
  const FirebaseEnvironmentStatus({
    required this.environment,
    required this.appName,
    required this.projectId,
    required this.databaseId,
    required this.localDataScope,
    this.host,
  });

  factory FirebaseEnvironmentStatus.fromConfiguration(
    FirebaseBackendConfiguration configuration,
  ) => FirebaseEnvironmentStatus(
    environment: configuration.environment,
    appName: configuration.appName,
    projectId: configuration.projectId,
    databaseId: configuration.databaseId,
    localDataScope: configuration.localDataScope,
    host: configuration.endpoints?.host,
  );

  final FirebaseEnvironment environment;
  final String appName;
  final String projectId;
  final String databaseId;
  final FirebaseLocalDataScope localDataScope;
  final String? host;

  bool get usesEmulators => environment == FirebaseEnvironment.emulator;
}

/// Persistent debug-only proof of the Firebase backend actually in use.
///
/// The banner reads the committed [FirebaseBackendConfiguration], not the
/// selector or saved preferences, so it cannot claim Live while an emulator
/// service instance is active.
class FirebaseEnvironmentBanner extends StatelessWidget {
  const FirebaseEnvironmentBanner({
    super.key,
    this.debugModeOverride,
    this.statusOverride,
  });

  final bool? debugModeOverride;
  final FirebaseEnvironmentStatus? statusOverride;

  bool get _isDebugMode => debugModeOverride ?? kDebugMode;

  @override
  Widget build(BuildContext context) {
    if (!_isDebugMode) return const SizedBox.shrink();

    final overridden = statusOverride;
    if (overridden != null) {
      return _BannerContents(status: overridden);
    }

    return ValueListenableBuilder<FirebaseBackendConfiguration?>(
      valueListenable: FirebaseBackend.configuration,
      builder: (context, configuration, child) {
        if (configuration == null) return const SizedBox.shrink();
        return _BannerContents(
          status: FirebaseEnvironmentStatus.fromConfiguration(configuration),
        );
      },
    );
  }
}

/// Adds the environment banner above a standalone bootstrap screen.
class FirebaseEnvironmentBannerFrame extends StatelessWidget {
  const FirebaseEnvironmentBannerFrame({
    super.key,
    required this.child,
    this.debugModeOverride,
  });

  final Widget child;
  final bool? debugModeOverride;

  @override
  Widget build(BuildContext context) {
    final isDebugMode = debugModeOverride ?? kDebugMode;
    if (!isDebugMode) return child;

    return ValueListenableBuilder<FirebaseBackendConfiguration?>(
      valueListenable: FirebaseBackend.configuration,
      builder: (context, configuration, _) {
        if (configuration == null) return child;
        return Column(
          children: [
            FirebaseEnvironmentBanner(
              debugModeOverride: true,
              statusOverride: FirebaseEnvironmentStatus.fromConfiguration(
                configuration,
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BannerContents extends StatelessWidget {
  const _BannerContents({required this.status});

  final FirebaseEnvironmentStatus status;

  @override
  Widget build(BuildContext context) {
    final emulator = status.usesEmulators;
    final background = emulator ? Colors.amber.shade800 : Colors.red.shade800;
    final foreground = Colors.white;

    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Semantics(
          button: true,
          label: firebaseEnvironmentSemantics(status),
          child: InkWell(
            onTap: () => showFirebaseEnvironmentDetails(context, status),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 30),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 520;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          emulator
                              ? Icons.developer_board
                              : Icons.warning_rounded,
                          size: 15,
                          color: foreground,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            firebaseEnvironmentSummary(
                              status,
                              compact: compact,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foreground,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.info_outline, size: 14, color: foreground),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
String firebaseEnvironmentSummary(
  FirebaseEnvironmentStatus status, {
  required bool compact,
}) {
  if (status.usesEmulators) {
    final host = status.host!;
    return compact
        ? 'EMULATOR · $host'
        : 'EMULATOR · $host · ${status.projectId} · ${status.databaseId}';
  }
  return compact
      ? 'LIVE FIREBASE · ${status.databaseId}'
      : 'LIVE FIREBASE · ${status.projectId} · ${status.databaseId}';
}

@visibleForTesting
String firebaseEnvironmentSemantics(FirebaseEnvironmentStatus status) {
  if (status.usesEmulators) {
    return 'Firebase environment Emulator at ${status.host}. '
        'Tap for routing details.';
  }
  return 'Firebase environment Live. Tap for routing details.';
}

Future<void> showFirebaseEnvironmentDetails(
  BuildContext context,
  FirebaseEnvironmentStatus status,
) {
  final host = status.host;
  final functionsRoute = host == null
      ? 'Live · ${FirebaseBackend.defaultFunctionsRegion}'
      : '$host:${FirebaseEmulatorEndpoints.functionsPort}';
  final authRoute = host == null
      ? 'Live'
      : '$host:${FirebaseEmulatorEndpoints.authPort}';
  final firestoreRoute = host == null
      ? 'Live · ${status.databaseId}'
      : '$host:${FirebaseEmulatorEndpoints.firestorePort} · '
            '${status.databaseId}';
  final storageRoute = host == null
      ? 'Live'
      : '$host:${FirebaseEmulatorEndpoints.storagePort}';

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(status.usesEmulators ? 'Firebase Emulator' : 'Live Firebase'),
      content: SingleChildScrollView(
        child: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Detail(label: 'App', value: status.appName),
              _Detail(label: 'Project', value: status.projectId),
              _Detail(label: 'Database', value: status.databaseId),
              _Detail(label: 'Authentication', value: authRoute),
              _Detail(label: 'Cloud Firestore', value: firestoreRoute),
              _Detail(label: 'Cloud Functions', value: functionsRoute),
              _Detail(label: 'Cloud Storage', value: storageRoute),
              _Detail(
                label: 'Local data',
                value:
                    '${status.localDataScope.name} · '
                    '${status.localDataScope.databaseName}',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(value),
        ],
      ),
    );
  }
}
