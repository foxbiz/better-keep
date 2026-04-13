import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'firebase_emulator_config.dart';

const _defaultRegion = 'us-central1';

/// Lightweight result wrapper matching [HttpsCallableResult.data].
class CloudFunctionResult {
  CloudFunctionResult(this.data);
  final dynamic data;
}

/// Calls a Firebase Cloud Function.
///
/// On Apple native platforms (iOS/macOS), makes a direct HTTPS
/// POST instead of using [FirebaseFunctions.httpsCallable] to avoid the
/// Swift concurrency SIGABRT crash in the native Firebase Functions SDK.
///
/// On web, delegates to [FirebaseFunctions.httpsCallable] since
/// browser CORS handling is managed by the SDK.
Future<CloudFunctionResult> callCloudFunction(
  String functionName, [
  Map<String, dynamic>? data,
  String region = _defaultRegion,
]) async {
  // On web and non-Apple/Windows platforms, use the standard SDK.
  if (kIsWeb || !(Platform.isIOS || Platform.isMacOS || Platform.isWindows)) {
    final functions = region == _defaultRegion
        ? FirebaseFunctions.instance
        : FirebaseFunctions.instanceFor(app: Firebase.app(), region: region);
    final result = await functions.httpsCallable(functionName).call(data ?? {});
    return CloudFunctionResult(result.data);
  }

  // On Apple native platforms: Direct HTTPS call to avoid native SDK crash
  final projectId = Firebase.app().options.projectId;

  final String baseUrl;
  if (kDebugMode && FirebaseEmulatorConfig.isUsingEmulators) {
    // Use emulator in debug mode
    baseUrl = 'http://localhost:5001/$projectId/$region';
  } else {
    baseUrl = 'https://$region-$projectId.cloudfunctions.net';
  }

  final url = Uri.parse('$baseUrl/$functionName');

  // Get auth token
  final user = FirebaseAuth.instance.currentUser;
  final idToken = user != null ? await user.getIdToken() : null;

  final headers = <String, String>{'Content-Type': 'application/json'};
  if (idToken != null) {
    headers['Authorization'] = 'Bearer $idToken';
  }

  final response = await http
      .post(url, headers: headers, body: jsonEncode({'data': data ?? {}}))
      .timeout(const Duration(seconds: 60));

  if (response.statusCode == 200) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return CloudFunctionResult(body['result']);
  }

  // Parse error response and throw FirebaseFunctionsException
  // to maintain compatibility with existing catch blocks
  Map<String, dynamic>? errorBody;
  try {
    errorBody = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (_) {}

  final error = errorBody?['error'] as Map<String, dynamic>?;
  final message = error?['message'] as String? ?? 'Cloud Function call failed';
  final status = error?['status'] as String? ?? 'INTERNAL';

  throw FirebaseFunctionsException(
    code: _mapStatusToCode(status),
    message: message,
  );
}

/// Maps HTTP/gRPC status strings to FirebaseFunctionsException error codes.
String _mapStatusToCode(String status) {
  switch (status) {
    case 'ALREADY_EXISTS':
      return 'already-exists';
    case 'INVALID_ARGUMENT':
      return 'invalid-argument';
    case 'FAILED_PRECONDITION':
      return 'failed-precondition';
    case 'UNAUTHENTICATED':
      return 'unauthenticated';
    case 'NOT_FOUND':
      return 'not-found';
    case 'PERMISSION_DENIED':
      return 'permission-denied';
    case 'RESOURCE_EXHAUSTED':
      return 'resource-exhausted';
    case 'UNAVAILABLE':
      return 'unavailable';
    case 'DEADLINE_EXCEEDED':
      return 'deadline-exceeded';
    case 'CANCELLED':
      return 'cancelled';
    default:
      return 'internal';
  }
}
