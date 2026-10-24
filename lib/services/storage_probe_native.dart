import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

Future<({int? availableBytes, double? usageRatio})> probeStorage() async {
  final directory = await getApplicationSupportDirectory();
  final bytes = await const MethodChannel('com.betterkeep/storage')
      .invokeMethod<int>('getAvailableBytes', directory.path);
  return (availableBytes: bytes, usageRatio: null);
}
