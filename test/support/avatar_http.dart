import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final avatarPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=',
);

class AvatarClient extends Fake implements HttpClient {
  final response = Completer<HttpClientResponse>();
  int requests = 0;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requests++;
    return AvatarRequest(response.future);
  }

  @override
  void close({bool force = false}) => closed = true;
}

class AvatarRequest extends Fake implements HttpClientRequest {
  AvatarRequest(this.response);
  final Future<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response;
}

class AvatarResponse extends Stream<List<int>> implements HttpClientResponse {
  AvatarResponse({this.statusCode = 200});
  @override
  final int statusCode;
  @override
  int get contentLength => avatarPng.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(avatarPng).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AvatarHttp extends HttpOverrides {
  final clients = <AvatarClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = AvatarClient();
    clients.add(client);
    return client;
  }
}
