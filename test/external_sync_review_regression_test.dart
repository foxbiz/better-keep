import 'dart:convert';
import 'dart:async';

import 'package:better_keep/services/external_sync/sync_json.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('timed out response streams are cancelled', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final client = _StreamingClient(() => stream.stream);
    await expectLater(
      ProviderHttp(
        client,
        timeout: const Duration(milliseconds: 10),
      ).send('GET', Uri.https('example.test', '/'), headers: {}),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.unavailable,
        ),
      ),
    );
    expect(cancelled, true);
    await stream.close();
    client.close();
  });

  test(
    'native and web numeric representations have identical fingerprints',
    () {
      expect(
        canonicalSyncJson({
          'ratio': 1.0,
          'flags': [0, 3.0],
        }),
        canonicalSyncJson(jsonDecode('{"flags":[0,3],"ratio":1}')),
      );
      expect(
        canonicalSyncJson({'a': -0.0, 'b': 1e20}),
        '{"a":0,"b":1.0000000000000000e+20}',
      );
    },
  );
  test('legacy fingerprint validation preserves original numeric lexemes', () {
    const source = '{"b":"escaped \\" 12", "a":[1.0,3,1.5e+20]}';
    expect(
      canonicalSyncJson(decodeLegacyFingerprintJson(source)),
      '{"a":[1.0,3,1.5e+20],"b":"escaped \\" 12"}',
    );
  });
  test(
    'oversize streamed responses stop before buffering all chunks',
    () async {
      var produced = 0;
      var cancelled = false;
      Stream<List<int>> bytes() async* {
        try {
          for (var i = 0; i < 100; i++) {
            produced++;
            yield List.filled(8, 0);
          }
        } finally {
          cancelled = true;
        }
      }

      final client = _StreamingClient(bytes);
      await expectLater(
        ProviderHttp(client).send(
          'GET',
          Uri.https('example.test', '/'),
          headers: {},
          maxResponseBytes: 10,
        ),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.corruptData,
          ),
        ),
      );
      expect(produced, 2);
      expect(cancelled, true);
      client.close();
    },
  );
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.bytes);
  final Stream<List<int>> Function() bytes;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(bytes(), 200);
}
