import 'dart:async';

import 'package:better_keep/utils/logger.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// The hardware models of iPhone Duo, from the device type that Xcode 27.2
/// installs for its simulator. Add a model here to give it the same layouts.
const _iPhoneDuoModels = {'iPhone19,4'};

bool _isIPhoneDuo = false;

@visibleForTesting
bool? debugIsIPhoneDuoOverride;

/// Whether this device is an iPhone Duo, folded or open.
///
/// Every layout made for it depends on this, so that a window of the same size
/// on any other device keeps its own layout. It does not change while the app
/// runs. False until [detectIPhoneDuo] has finished.
bool get isIPhoneDuo => debugIsIPhoneDuoOverride ?? _isIPhoneDuo;

@visibleForTesting
bool isIPhoneDuoModel(String machine) => _iPhoneDuoModels.contains(machine);

/// Called once, before the app is shown: layouts read [isIPhoneDuo] while they
/// build and are not told of a change.
Future<void> detectIPhoneDuo() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    final info = await DeviceInfoPlugin().iosInfo.timeout(
      const Duration(seconds: 1),
    );
    final model = info.utsname.machine;
    _isIPhoneDuo = isIPhoneDuoModel(model);
    unawaited(
      AppLogger.log(
        '[Device] $model, iPhone Duo layouts ${_isIPhoneDuo ? 'on' : 'off'}',
      ),
    );
  } catch (error) {
    // A device we cannot name keeps the layout of any other device. Launch
    // does not wait for it.
    unawaited(AppLogger.log('[Device] model unknown: $error'));
  }
}
