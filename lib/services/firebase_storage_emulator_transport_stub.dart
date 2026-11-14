import 'firebase_emulator_host.dart';

Future<Uri> configureStorageEmulatorTransport(
  FirebaseEmulatorEndpoints endpoints, {
  required String projectId,
}) async => Uri(
  scheme: 'http',
  host: endpoints.host,
  port: FirebaseEmulatorEndpoints.storagePort,
);
