import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';

import '../../core/logging.dart';
import '../../core/permissions.dart';
import '../audio/mic_hub.dart';
import 'engine.dart';
import 'isolate_engine.dart' show MicSource, PreRollBuffer;
import 'pcm_ring.dart';

typedef CentralSocket = Future<WebSocket> Function(Uri uri, String token);

Future<WebSocket> _connect(Uri uri, String token) => WebSocket.connect(
  uri.toString(),
  headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
);

/// Capture-only native engine. No local wake model is loaded or run. A fresh
/// stream has its own zero-based sample clock; [_sourceSamples] is the mic's
/// clock and never resets until capture is reopened.
class CentralWakeEngine extends WakeWordEngine {
  CentralWakeEngine(
    this.log, {
    required this.homeAssistantUrl,
    required this.token,
    required this.endpointId,
    required this.onAvailability,
    MicSource? mic,
    CentralSocket? connect,
    Future<PermissionOutcome> Function()? micPermission,
  }) : _mic = mic ?? (() => MicHub.instance.stream()),
       _connectSocket = connect ?? _connect,
       _micPermission =
           micPermission ?? (() => requestOsPermission(Permission.microphone));

  final Logger log;
  final String Function() homeAssistantUrl;
  final String Function() token;
  final String Function() endpointId;
  final void Function(bool ready) onAvailability;
  final MicSource _mic;
  final CentralSocket _connectSocket;
  final Future<PermissionOutcome> Function() _micPermission;
  final PreRollBuffer _preRoll = PreRollBuffer(
    maxChunks: 126,
    maxRecentSamples: 160000,
  );
  final PcmRing _recent = PcmRing(160000);

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<dynamic>? _socketSub;
  WebSocket? _socket;
  Timer? _retry;
  Timer? _readyTimeout;
  DetectionCallback? _onDetection;
  WakeWordConfig? _config;
  void Function(Uint8List, bool)? _audioSink;
  bool _running = false;
  bool _paused = false;
  bool _ready = false;
  int _generation = 0;
  int _socketEpoch = 0;
  int _sourceSamples = 0;
  int _streamBase = 0;
  int _sentSamples = 0;
  String? _streamId;
  final Set<String> _seenEvents = {};
  final Queue<String> _eventOrder = Queue<String>();

  bool get connected => _ready;
  @override
  bool get running => _running;
  @override
  Set<WakeWordEngineType> get supportedEngines =>
      WakeWordEngineType.values.toSet();
  @override
  set recordAudio(bool enabled) {
    if (!enabled) _recent.clear();
    _recordAudio = enabled;
  }

  bool _recordAudio = false;
  @override
  Uint8List? recentAudio(Duration length) =>
      _recordAudio ? _recent.last(length.inMilliseconds * 16) : null;
  @override
  void clearRecentAudio() => _recent.clear();
  @override
  String? get wakeHandoffError => _preRoll.handoffLost
      ? 'Wake audio handoff exceeded the buffer; please repeat your request'
      : null;
  @override
  void clearWakeHandoff() => _preRoll.clearHandoff();

  @override
  Future<void> start({
    required WakeWordConfig config,
    required DetectionCallback onDetection,
    StopDetectionCallback? onStopDetection,
    EngineFailureCallback? onFailure,
  }) async {
    if (_running) return;
    _config = config;
    _onDetection = onDetection;
    final permission = await _micPermission();
    if (permission != PermissionOutcome.granted) {
      onFailure?.call(
        permission == PermissionOutcome.blocked
            ? EngineFailure.micBlocked
            : EngineFailure.micDeclined,
        'central wake microphone permission refused',
      );
      return;
    }
    _preRoll.reset();
    _sourceSamples = 0;
    _running = true;
    final generation = ++_generation;
    void microphoneLost(String reason) {
      if (!_running || generation != _generation) return;
      log.error('central_wake', reason);
      unawaited(
        stop().then((_) => onFailure?.call(EngineFailure.micLost, reason)),
      );
    }

    _micSub = _mic().listen(
      _onMic,
      onError: (Object error) => microphoneLost('microphone failed: $error'),
      onDone: () => microphoneLost('microphone stream ended'),
    );
    unawaited(_openSocket(generation));
  }

  Uri? _streamUri() {
    final origin = Uri.tryParse(homeAssistantUrl());
    if (origin == null ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(origin.scheme) ||
        token().isEmpty ||
        endpointId().isEmpty) {
      return null;
    }
    return origin.replace(
      scheme: origin.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/luna_endpoints/wake-stream',
      queryParameters: {'endpoint_id': endpointId()},
      fragment: '',
    );
  }

  Future<void> _openSocket(int generation) async {
    if (!_running || generation != _generation) return;
    final socketEpoch = ++_socketEpoch;
    final uri = _streamUri();
    if (uri == null) {
      _disconnected(
        generation,
        socketEpoch,
        'missing Home Assistant wake stream settings',
      );
      return;
    }
    try {
      final socket = await _connectSocket(uri, token())
          .then((opened) {
            // Future.timeout does not cancel a pending WebSocket.connect.
            if (!_running ||
                generation != _generation ||
                socketEpoch != _socketEpoch) {
              unawaited(opened.close());
              throw StateError('stale central wake connection');
            }
            return opened;
          })
          .timeout(const Duration(seconds: 5));
      if (!_running ||
          generation != _generation ||
          socketEpoch != _socketEpoch) {
        await socket.close();
        return;
      }
      _socket = socket;
      // A stalled connection must close before its outbound sink can retain
      // more than a short window of live audio.
      socket.pingInterval = const Duration(seconds: 5);
      _ready = false;
      _seenEvents.clear();
      _eventOrder.clear();
      _streamId = _uuid();
      _socketSub = socket.listen(
        (message) => _onMessage(message, generation, socketEpoch),
        onError: (Object error) =>
            _disconnected(generation, socketEpoch, '$error'),
        onDone: () => _disconnected(generation, socketEpoch, 'socket closed'),
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'type': 'start',
          'stream_id': _streamId,
          'endpoint_id': endpointId(),
          'sample_rate': 16000,
          'format': 'pcm16',
        }),
      );
      _readyTimeout = Timer(const Duration(seconds: 5), () {
        if (!_ready) _disconnected(generation, socketEpoch, 'ready timeout');
      });
    } catch (error) {
      _disconnected(generation, socketEpoch, '$error');
    }
  }

  void _disconnected(int generation, int socketEpoch, String reason) {
    if (!_running || generation != _generation || socketEpoch != _socketEpoch) {
      return;
    }
    _socketEpoch++;
    _readyTimeout?.cancel();
    _ready = false;
    _streamId = null;
    _seenEvents.clear();
    _eventOrder.clear();
    onAvailability(false);
    final socket = _socket;
    _socket = null;
    unawaited(_socketSub?.cancel() ?? Future.value());
    _socketSub = null;
    if (socket != null) unawaited(socket.close());
    log.warn('central_wake', 'stream unavailable: $reason');
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () => _openSocket(generation));
  }

  void _onMessage(dynamic raw, int generation, int socketEpoch) {
    if (!_running ||
        generation != _generation ||
        socketEpoch != _socketEpoch ||
        raw is! String ||
        raw.length > 2048) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['stream_id'] != _streamId) return;
    if (decoded['type'] == 'ready') {
      if (_ready) return;
      _readyTimeout?.cancel();
      // No buffered or stale audio crosses reconnect. The next mic sample is
      // stream sample zero, with this source epoch as its translation base.
      _streamBase = _sourceSamples;
      _sentSamples = 0;
      _ready = true;
      onAvailability(true);
      if (_paused) {
        _socket?.add(jsonEncode({'type': 'pause', 'stream_id': _streamId}));
      }
      return;
    }
    if (decoded['type'] != 'wake' || !_ready || _paused) return;
    final eventId = decoded['event_id'];
    final from = decoded['audio_start_sample'];
    final detected = decoded['detected_at_sample'];
    if (eventId is! String ||
        !_uuidPattern.hasMatch(eventId) ||
        from is! int ||
        detected is! int ||
        from < 0 ||
        detected <= from ||
        detected > _sentSamples ||
        from > _sentSamples ||
        _seenEvents.contains(eventId)) {
      return;
    }
    _seenEvents.add(eventId);
    _eventOrder.addLast(eventId);
    if (_eventOrder.length > 128) {
      _seenEvents.remove(_eventOrder.removeFirst());
    }
    // A wake older than our bounded ten-second mic history cannot be safely
    // dispatched. The pre-roll reports the lost handoff to the manager.
    final sourceStart = _streamBase + from;
    _preRoll.pinFrom(sourceStart);
    if (_preRoll.handoffLost) {
      _preRoll.clearHandoff();
      _socket?.add(jsonEncode({'type': 'resume', 'stream_id': _streamId}));
      return;
    }
    unawaited(pauseDetection());
    final model = _config?.models.firstOrNull;
    if (model != null) unawaited(_onDetection?.call(model) ?? Future.value());
  }

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final value = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  void _onMic(Uint8List pcm) {
    if (!_running || pcm.length.isOdd) return;
    final sourceStart = _sourceSamples;
    _sourceSamples += pcm.length ~/ 2;
    _preRoll.add(pcm);
    if (_recordAudio) _recent.add(pcm);
    _audioSink?.call(pcm, false);
    if (!_ready || _socket == null) return;
    // Native chunks are normally 1280 samples; split larger device chunks so
    // the wire never exceeds 6400 samples. No send queue or stale replay.
    for (var offset = 0; offset < pcm.length; offset += 12800) {
      final end = min(offset + 12800, pcm.length);
      final first = sourceStart + offset ~/ 2 - _streamBase;
      if (first != _sentSamples) {
        _disconnected(_generation, _socketEpoch, 'non-contiguous capture');
        return;
      }
      final frame = Uint8List(8 + end - offset);
      ByteData.sublistView(frame).setUint64(0, first, Endian.little);
      frame.setRange(8, frame.length, pcm.sublist(offset, end));
      try {
        _socket!.add(frame);
      } catch (error) {
        _disconnected(_generation, _socketEpoch, '$error');
        return;
      }
      _sentSamples += (end - offset) ~/ 2;
    }
  }

  @override
  Future<void> pauseDetection() async {
    if (_paused) return;
    _paused = true;
    if (_ready) {
      _socket?.add(jsonEncode({'type': 'pause', 'stream_id': _streamId}));
    }
  }

  @override
  Future<void> resumeDetection() async {
    if (!_paused) return;
    _paused = false;
    _preRoll.clearHandoff();
    if (_ready) {
      _socket?.add(jsonEncode({'type': 'resume', 'stream_id': _streamId}));
    }
  }

  @override
  Future<void> startAudioStream(void Function(Uint8List, bool) onChunk) async {
    _audioSink = null;
    final chunks = _preRoll.hasHandoff
        ? _preRoll.takeHandoff()
        : _preRoll.flush(null);
    _audioSink = onChunk;
    for (final chunk in chunks) {
      onChunk(chunk, true);
    }
  }

  @override
  Future<void> stopAudioStream() async {
    _audioSink = null;
  }

  @override
  Future<void> stop() async {
    _generation++;
    _socketEpoch++;
    _running = false;
    _ready = false;
    _paused = false;
    _retry?.cancel();
    _readyTimeout?.cancel();
    await _micSub?.cancel();
    _micSub = null;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close();
    _audioSink = null;
    _streamId = null;
    _seenEvents.clear();
    _eventOrder.clear();
    _preRoll.reset();
    _recent.clear();
    onAvailability(false);
  }
}
