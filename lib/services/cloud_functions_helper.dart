import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'firebase_backend.dart';
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
    final functions = FirebaseBackend.functions(region: region);
    final result = await functions.httpsCallable(functionName).call(data ?? {});
    return CloudFunctionResult(result.data);
  }

  // On Apple native platforms: Direct HTTPS call to avoid native SDK crash
  final projectId = FirebaseBackend.projectId;

  final String baseUrl;
  if (kDebugMode && FirebaseEmulatorConfig.isUsingEmulators) {
    baseUrl = FirebaseEmulatorConfig.endpoints.functionsBaseUrl(
      projectId: projectId,
      region: region,
    );
  } else {
    baseUrl = 'https://$region-$projectId.cloudfunctions.net';
  }

  final url = Uri.parse('$baseUrl/$functionName');

  // Get auth token
  final user = FirebaseBackend.auth.currentUser;
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

  throw parseCloudFunctionError(response.body);
}

/// Maps the direct HTTP transport's callable error without losing structured details.
@visibleForTesting
FirebaseFunctionsException parseCloudFunctionError(String responseBody) {
  Map? error;
  try {
    final body = jsonDecode(responseBody);
    if (body is Map && body['error'] is Map) error = body['error'] as Map;
  } catch (_) {}

  final message = error?['message'];
  final status = error?['status'];
  return FirebaseFunctionsException(
    code: _mapStatusToCode(status is String ? status : 'INTERNAL'),
    message: message is String ? message : 'Cloud Function call failed',
    details: error?['details'],
  );
}

/// Maps HTTP/gRPC status strings to FirebaseFunctionsException error codes.
String _mapStatusToCode(String status) {
  switch (status) {
    case 'ABORTED':
      return 'aborted';
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
