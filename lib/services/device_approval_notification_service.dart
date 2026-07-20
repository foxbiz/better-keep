import 'dart:async';

import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/utils/logger.dart';

/// Service to show local notifications for incoming device approval requests
class DeviceApprovalNotificationService {
  static final DeviceApprovalNotificationService _instance =
      DeviceApprovalNotificationService._internal();
  factory DeviceApprovalNotificationService() => _instance;
  DeviceApprovalNotificationService._internal();

  List<DeviceApprovalRequest> _lastKnownApprovals = [];
  bool _initialized = false;
  bool _listenerAttached = false;

  /// Initialize the notification service
  Future<void> init() async {
    if (_initialized) return;
    if (!LocalNotificationService
        .instance
        .supportsDeviceApprovalNotifications) {
      return;
    }
    await ReminderCoordinator.instance.init();

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
    if (_listenerAttached) {
      E2EEService.instance.deviceManager.pendingApprovals.removeListener(
        _onPendingApprovalsChanged,
      );
      _listenerAttached = false;
    }
    _initialized = false;
  }

  void _onPendingApprovalsChanged() {
    unawaited(
      _handlePendingApprovalsChanged().catchError(
        (Object error, StackTrace stackTrace) => AppLogger.error(
          'Failed to process device approval notification update',
          error,
          stackTrace,
        ),
      ),
    );
  }

  Future<void> _handlePendingApprovalsChanged() async {
    // Only show notifications on master device
    final isMaster = await E2EEService.instance.deviceManager.isMasterDevice();
    if (!isMaster) return;

    final currentApprovals =
        E2EEService.instance.deviceManager.pendingApprovals.value;

    // Find new approvals (not in last known list)
    for (final approval in currentApprovals) {
      final isNew = !_lastKnownApprovals.any(
        (old) => old.deviceId == approval.deviceId,
      );

      if (isNew) {
        await _showApprovalNotification(approval);
      }
    }

    // Update last known state
    _lastKnownApprovals = List.from(currentApprovals);
  }

  Future<bool> _showApprovalNotification(DeviceApprovalRequest request) async {
    final platformName = _formatPlatform(request.platform);

    // Use device ID hash as notification ID to avoid duplicates
    final notificationId = _notificationId(request.deviceId);

    final shown = await LocalNotificationService.instance.showDeviceApproval(
      id: notificationId,
      title: 'New Device Approval Request',
      body: '${request.deviceName} ($platformName) wants to access your notes',
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

  String _formatPlatform(String platform) {
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
        return 'Web';
      default:
        return platform;
    }
  }
}
