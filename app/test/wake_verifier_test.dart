import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_verifier.dart';

void main() {
  test(
    'sends an exact WAV only to configured HA and requires request echo',
    () async {
      late http.Request sent;
      final verifier = WakeVerifier(
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'request_id': request.url.queryParameters['request_id'],
              'accepted': true,
              'reason': 'matched',
              'elapsed_ms': 314,
            }),
            200,
          );
        }),
      );
      final reply = await verifier.verify(
        homeAssistantUrl: 'http://192.168.0.139:8123/lovelace/0',
        token: 'test-token',
        endpointId: 'voice-garage',
        pcm: Uint8List(96000),
      );
      expect(reply.accepted, isTrue);
      expect(reply.reason, 'matched');
      expect(sent.url.origin, 'http://192.168.0.139:8123');
      expect(sent.url.path, '/api/luna_endpoints/wake-verify');
      expect(sent.url.queryParameters['endpoint_id'], 'voice-garage');
      expect(sent.followRedirects, isFalse);
      expect(sent.headers['Authorization'], 'Bearer test-token');
      expect(sent.headers['Content-Type'], 'audio/wav');
      expect(sent.bodyBytes.length, 96044);
      expect(utf8.decode(sent.bodyBytes.sublist(0, 4)), 'RIFF');
      expect(
        ByteData.sublistView(sent.bodyBytes).getUint32(40, Endian.little),
        96000,
      );
      verifier.close();
    },
  );

  test('wrong request echo and redirect fail closed', () async {
    final wrong = WakeVerifier(
      client: MockClient(
        (_) async => http.Response(
          '{"request_id":"other","accepted":true,"reason":"matched","elapsed_ms":1}',
          200,
        ),
      ),
    );
    expect(
      (await wrong.verify(
        homeAssistantUrl: 'https://ha.example',
        token: 'test-token',
        endpointId: 'garage',
        pcm: Uint8List(96000),
      )).accepted,
      isFalse,
    );
    wrong.close();
    final redirect = WakeVerifier(
      client: MockClient(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': 'https://elsewhere.example'},
        ),
      ),
    );
    expect(
      (await redirect.verify(
        homeAssistantUrl: 'https://ha.example',
        token: 'test-token',
        endpointId: 'garage',
        pcm: Uint8List(96000),
      )).accepted,
      isFalse,
    );
    redirect.close();
  });

  test('rejects invalid origin before sending audio', () async {
    var calls = 0;
    final verifier = WakeVerifier(
      client: MockClient((_) async {
        calls++;
        return http.Response('', 200);
      }),
    );
    final reply = await verifier.verify(
      homeAssistantUrl: 'https://user:password@ha.example',
      token: 'test-token',
      endpointId: 'garage',
      pcm: Uint8List(96000),
    );
    expect(reply.accepted, isFalse);
    expect(calls, 0);
    verifier.close();
  });

  test('rejects oversized, malformed, and inconsistent replies', () async {
    final replies = <http.StreamedResponse>[
      http.StreamedResponse(Stream.value(Uint8List(1025)), 200),
      http.StreamedResponse(Stream.value(utf8.encode('{bad json')), 200),
      http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'request_id': 'wrong',
              'accepted': true,
              'reason': 'matched',
              'elapsed_ms': 1,
            }),
          ),
        ),
        200,
      ),
    ];
    for (final response in replies) {
      final verifier = WakeVerifier(
        client: MockClient.streaming((_, _) async => response),
      );
      final result = await verifier.verify(
        homeAssistantUrl: 'http://ha.example:8123',
        token: 'test-token',
        endpointId: 'garage',
        pcm: Uint8List(96000),
      );
      expect(result.accepted, isFalse);
      verifier.close();
    }
    final inconsistent = WakeVerifier(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'request_id': request.url.queryParameters['request_id'],
            'accepted': true,
            'reason': 'no_match',
            'elapsed_ms': 1,
          }),
          200,
        ),
      ),
    );
    expect(
      (await inconsistent.verify(
        homeAssistantUrl: 'http://ha.example',
        token: 'test-token',
        endpointId: 'garage',
        pcm: Uint8List(96000),
      )).accepted,
      isFalse,
    );
    inconsistent.close();
  });

  test('one deadline covers a stalled response body', () async {
    final pending = Completer<void>();
    final verifier = WakeVerifier(
      timeout: const Duration(milliseconds: 10),
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          pending.future.asStream().expand((_) => [utf8.encode('{}')]),
          200,
        ),
      ),
    );
    final result = await verifier.verify(
      homeAssistantUrl: 'http://ha.example',
      token: 'test-token',
      endpointId: 'garage',
      pcm: Uint8List(96000),
    );
    expect(result.accepted, isFalse);
    expect(result.reason, 'timeout');
    pending.complete();
    verifier.close();
  });
}
