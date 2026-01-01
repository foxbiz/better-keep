import 'dart:io';

import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service to show local notifications for incoming device approval requests
class DeviceApprovalNotificationService {
  static final DeviceApprovalNotificationService _instance =
      DeviceApprovalNotificationService._internal();
  factory DeviceApprovalNotificationService() => _instance;
  DeviceApprovalNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'device_approval';
  static const String _channelName = 'Device Approval';
  static const String _channelDescription =
      'Notifications for new device approval requests';

  List<DeviceApprovalRequest> _lastKnownApprovals = [];
  bool _initialized = false;

  /// Initialize the notification service
  Future<void> init() async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const macosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: macosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    // Create Android notification channel
    if (Platform.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );
    }

    // Listen to pending approvals changes
    E2EEService.instance.deviceManager.pendingApprovals.addListener(
      _onPendingApprovalsChanged,
    );

    // Store initial state
    _lastKnownApprovals = List.from(
      E2EEService.instance.deviceManager.pendingApprovals.value,
    );

    _initialized = true;
  }

  void dispose() {
    E2EEService.instance.deviceManager.pendingApprovals.removeListener(
      _onPendingApprovalsChanged,
    );
  }

  void _onPendingApprovalsChanged() async {
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
        _showApprovalNotification(approval);
      }
    }

    // Update last known state
    _lastKnownApprovals = List.from(currentApprovals);
  }

  Future<void> _showApprovalNotification(DeviceApprovalRequest request) async {
    final platformName = _formatPlatform(request.platform);

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();

    const macosDetails = DarwinNotificationDetails();

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: macosDetails,
    );

    // Use device ID hash as notification ID to avoid duplicates
    final notificationId = request.deviceId.hashCode.abs() % 100000;

    await _notifications.show(
      notificationId,
      'New Device Approval Request',
      '${request.deviceName} ($platformName) wants to access your notes',
      details,
      payload: request.deviceId,
    );
  }

  void _onNotificationResponse(NotificationResponse response) {
    // User tapped notification - app will open to handle it
  }

  /// Cancel notification for a specific device
  Future<void> cancelNotification(String deviceId) async {
    final notificationId = deviceId.hashCode.abs() % 100000;
    await _notifications.cancel(notificationId);
  }

  /// Cancel all device approval notifications
  Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
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
