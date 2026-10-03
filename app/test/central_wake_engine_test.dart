import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/core/permissions.dart';
import 'package:kiosk_satellite/managers/wake_word/central_wake_engine.dart';
import 'package:kiosk_satellite/managers/wake_word/engine.dart';

const _model = WakeWordModelRef(
  id: 'hey_luna',
  wakeWord: 'Hey Luna',
  manifestUrl: 'unused',
);
const _config = WakeWordConfig(
  engine: WakeWordEngineType.vsWakeWord,
  models: [_model],
);

Future<T> _eventually<T>(T? Function() read) async {
  for (var i = 0; i < 400; i++) {
    final value = read();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('timed out');
}

void main() {
  test('a connection completing after capture stops is closed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var closed = false;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (_) {},
        onDone: () {
          closed = true;
        },
      );
    });
    final pending = Completer<WebSocket>();
    final mic = StreamController<Uint8List>.broadcast(sync: true);
    final engine = CentralWakeEngine(
      Logger(),
      homeAssistantUrl: () => 'http://127.0.0.1:${server.port}',
      token: () => 'test-token',
      endpointId: () => 'voice-garage',
      onAvailability: (_) {},
      mic: () => mic.stream,
      micPermission: () async => PermissionOutcome.granted,
      connect: (_, _) => pending.future,
    );
    try {
      await engine.start(config: _config, onDetection: (_) async {});
      await engine.stop();
      pending.complete(
        await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/api/luna_endpoints/wake-stream',
        ),
      );
      await _eventually(() => closed ? true : null);
    } finally {
      await engine.stop();
      await mic.close();
      await server.close(force: true);
    }
  });

  test(
    'central stream translates epochs, pins wake audio, and rejects stale wakes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mic = StreamController<Uint8List>.broadcast(sync: true);
      final sockets = <WebSocket>[];
      final messages = <List<Object>>[];
      final streamIds = <String>[];
      final auth = <String?>[];
      server.listen((request) async {
        auth.add(request.headers.value(HttpHeaders.authorizationHeader));
        expect(request.uri.path, '/api/luna_endpoints/wake-stream');
        expect(request.uri.queryParameters['endpoint_id'], 'voice-garage');
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        final frames = <Object>[];
        messages.add(frames);
        socket.listen((raw) {
          frames.add(raw);
          if (raw is String) {
            final message = jsonDecode(raw) as Map;
            if (message['type'] == 'start') {
              streamIds.add(message['stream_id'] as String);
              expect(message['sample_rate'], 16000);
              expect(message['format'], 'pcm16');
              socket.add(
                jsonEncode({
                  'type': 'ready',
                  'stream_id': message['stream_id'],
                }),
              );
            }
          }
        });
      });
      final detections = <WakeWordModelRef>[];
      final availability = <bool>[];
      final failures = <EngineFailure>[];
      final engine = CentralWakeEngine(
        Logger(),
        homeAssistantUrl: () => 'http://127.0.0.1:${server.port}',
        token: () => 'test-token',
        endpointId: () => 'voice-garage',
        onAvailability: availability.add,
        mic: () => mic.stream,
        micPermission: () async => PermissionOutcome.granted,
      );
      try {
        await engine.start(
          config: _config,
          onDetection: (model) async {
            detections.add(model);
          },
          onFailure: (failure, _) => failures.add(failure),
        );
        await _eventually(() => engine.connected ? true : null);
        expect(auth, ['Bearer test-token']);
        mic.add(Uint8List.fromList([1, 0, 2, 0, 3, 0, 4, 0]));
        final first = await _eventually(
          () => messages.first.whereType<List<int>>().firstOrNull,
        );
        expect(
          ByteData.sublistView(
            Uint8List.fromList(first),
          ).getUint64(0, Endian.little),
          0,
        );
        expect(first.sublist(8), [1, 0, 2, 0, 3, 0, 4, 0]);

        final wake = {
          'type': 'wake',
          'stream_id': streamIds.first,
          'event_id': '11111111-1111-4111-8111-111111111111',
          'audio_start_sample': 0,
          'detected_at_sample': 4,
        };
        sockets.first.add(jsonEncode(wake));
        await _eventually(() => detections.isNotEmpty ? true : null);
        final replay = <int>[];
        await engine.startAudioStream((pcm, old) {
          if (old) replay.addAll(pcm);
        });
        expect(replay, [1, 0, 2, 0, 3, 0, 4, 0]);
        sockets.first.add(jsonEncode(wake));
        sockets.first.add(
          jsonEncode({
            ...wake,
            'event_id': '22222222-2222-4222-8222-222222222222',
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(detections, hasLength(1));

        await sockets.first.close();
        await _eventually(() => !engine.connected ? true : null);
        await _eventually(() => streamIds.length == 2 ? true : null);
        await _eventually(() => engine.connected ? true : null);
        mic.add(Uint8List.fromList([5, 0, 6, 0]));
        final next = await _eventually(
          () => messages[1].whereType<List<int>>().firstOrNull,
        );
        expect(
          ByteData.sublistView(
            Uint8List.fromList(next),
          ).getUint64(0, Endian.little),
          0,
        );
        // Old stream replies and wake events received during a paused turn
        // cannot dispatch after reconnect.
        sockets[1].add(jsonEncode({...wake, 'stream_id': streamIds.first}));
        sockets[1].add(jsonEncode({...wake, 'stream_id': streamIds[1]}));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(detections, hasLength(1));
        await engine.resumeDetection();
        mic.add(Uint8List(320002)); // exceeds the ten-second source history
        await _eventually(
          () => messages[1].whereType<List<int>>().length >= 27 ? true : null,
        );
        final resumeCount = messages[1]
            .whereType<String>()
            .where((raw) => (jsonDecode(raw) as Map)['type'] == 'resume')
            .length;
        sockets[1].add(
          jsonEncode({
            ...wake,
            'stream_id': streamIds[1],
            'event_id': '33333333-3333-4333-8333-333333333333',
          }),
        );
        await _eventually(
          () =>
              messages[1]
                      .whereType<String>()
                      .where(
                        (raw) => (jsonDecode(raw) as Map)['type'] == 'resume',
                      )
                      .length >
                  resumeCount
              ? true
              : null,
        );
        expect(detections, hasLength(1));
        await mic.close();
        await _eventually(() => failures.isNotEmpty ? true : null);
        expect(failures, [EngineFailure.micLost]);
        expect(engine.running, false);
        expect(availability.last, false);
      } finally {
        await engine.stop();
        await mic.close();
        await server.close(force: true);
      }
    },
  );
}
