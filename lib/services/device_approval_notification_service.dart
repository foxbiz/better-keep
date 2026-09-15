import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'dart:async';

import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/device_localizations.dart';

/// Service to show local notifications for incoming device approval requests
class DeviceApprovalNotificationService {
  static final DeviceApprovalNotificationService _instance =
      DeviceApprovalNotificationService._internal();
  factory DeviceApprovalNotificationService() => _instance;
  DeviceApprovalNotificationService._internal();

  List<DeviceApprovalRequest> _lastKnownApprovals = [];
  bool _initialized = false;
  int _generation = 0;
  final _initializationGate = AsyncInitializationGate();
  bool _listenerAttached = false;

  /// Initialize the notification service
  Future<void> init() => _initializationGate.run(_init);

  Future<void> _init() async {
    if (_initialized) return;
    if (!LocalNotificationService
        .instance
        .supportsDeviceApprovalNotifications) {
      return;
    }
    final current = AuthService.captureSession();
    final generation = _generation;
    await ReminderCoordinator.instance.init();
    if (!current() || generation != _generation) return;

    // Listen to pending approvals changes
    E2EEService.instance.deviceManager.pendingApprovals.addListener(
      _onPendingApprovalsChanged,
    );
    _listenerAttached = true;

    // Store initial state
    _lastKnownApprovals = List.from(
      E2EEService.instance.deviceManager.pendingApprovals.value,
    );

    _initialized = true;
  }

  void dispose() {
    _generation++;
    _initializationGate.reset();
    if (_listenerAttached) {
      E2EEService.instance.deviceManager.pendingApprovals.removeListener(
        _onPendingApprovalsChanged,
      );
      _listenerAttached = false;
    }
    _initialized = false;
  }

  void _onPendingApprovalsChanged() {
    final accountCurrent = AuthService.captureSession();
    final generation = _generation;
    unawaited(
      bindBackgroundCloudOperation(
        () => accountCurrent() && generation == _generation && _initialized,
        _handlePendingApprovalsChanged,
        onError: (error, stackTrace) {
          AppLogger.error(
            'Failed to process device approval notification update',
            error,
            stackTrace,
          );
        },
      )(),
    );
  }

  Future<void> _handlePendingApprovalsChanged() async {
    // Only show notifications on master device
    final current = AuthService.captureSession();
    final generation = _generation;
    final isMaster = await E2EEService.instance.deviceManager.isMasterDevice();
    if (!current() || generation != _generation) return;
    if (!isMaster) return;

    final currentApprovals =
        E2EEService.instance.deviceManager.pendingApprovals.value;

    // Find new approvals (not in last known list)
    for (final approval in currentApprovals) {
      final isNew = !_lastKnownApprovals.any(
        (old) => old.deviceId == approval.deviceId,
      );

      if (!current() || generation != _generation) return;
      if (isNew) {
        await _showApprovalNotification(approval);
      }
    }

    if (!current() || generation != _generation) return;
    // Update last known state
    _lastKnownApprovals = List.from(currentApprovals);
  }

  Future<bool> _showApprovalNotification(DeviceApprovalRequest request) async {
    // Use device ID hash as notification ID to avoid duplicates
    final notificationId = _notificationId(request.deviceId);
    final l10n = currentAppLocalizations();
    final platformName = _formatPlatform(request.platform, l10n.webBrowser);

    final shown = await LocalNotificationService.instance.showDeviceApproval(
      id: notificationId,
      title: l10n.newDeviceApprovalRequest,
      body: l10n.deviceWantsAccess(
        localizedDeviceName(l10n, request.deviceName),
        platformName,
      ),
      payload: request.deviceId,
    );
    if (!shown) {
      await AppLogger.log(
        'Device approval notification skipped: unsupported platform',
      );
    }
    return shown;
  }

  /// Cancel notification for a specific device
  Future<void> cancelNotification(String deviceId) async {
    await LocalNotificationService.instance.cancelDeviceApproval(
      _notificationId(deviceId),
    );
  }

  /// Cancel all device approval notifications
  Future<void> cancelAllNotifications() async {
    for (final approval in _lastKnownApprovals) {
      await cancelNotification(approval.deviceId);
    }
    _lastKnownApprovals = [];
  }

  int _notificationId(String deviceId) {
    var hash = 0x811c9dc5;
    for (final unit in 'approval:$deviceId'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  String _formatPlatform(String platform, String localizedWebBrowser) {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'web':
        return localizedWebBrowser;
      default:
        return platform;
    }
  }
}
