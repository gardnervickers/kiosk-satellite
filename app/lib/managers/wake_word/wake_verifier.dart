import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Sends a bounded candidate only to the already configured Home Assistant
/// origin. HA authenticates the Portal and forwards audio to the fixed local
/// verifier; the bearer token is sent to HA only.
class WakeVerifier {
  WakeVerifier({http.Client? client,
      this.timeout = const Duration(milliseconds: 1500)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<WakeVerifyReply> verify({
    required String homeAssistantUrl,
    required String token,
    required String endpointId,
    required Uint8List pcm,
  }) async {
    if (pcm.length != 96000 || token.isEmpty || endpointId.isEmpty) {
      return const WakeVerifyReply(false, 'not_configured', 0);
    }
    final origin = Uri.tryParse(homeAssistantUrl);
    if (origin == null || !origin.hasScheme || origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(origin.scheme)) {
      return const WakeVerifyReply(false, 'invalid_ha_origin', 0);
    }
    final requestId = _requestId();
    final uri = origin.replace(
      path: '/api/luna_endpoints/wake-verify',
      queryParameters: {'endpoint_id': endpointId, 'request_id': requestId},
      fragment: '',
    );
    final abort = Completer<void>();
    final request = http.AbortableRequest('POST', uri,
        abortTrigger: abort.future)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'audio/wav'
      ..bodyBytes = wav16k(pcm);
    Future<WakeVerifyReply> exchange() async {
      final streamed = await _client.send(request);
      if (streamed.statusCode != 200) {
        return WakeVerifyReply(false, 'http_${streamed.statusCode}', 0);
      }
      if ((streamed.contentLength ?? 0) > 1024) {
        return const WakeVerifyReply(false, 'oversized_reply', 0);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > 1024) {
          return const WakeVerifyReply(false, 'oversized_reply', 0);
        }
        bytes.add(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      final reason = body is Map ? body['reason'] : null;
      final elapsed = body is Map ? body['elapsed_ms'] : null;
      if (body is! Map || body['request_id'] != requestId ||
          body['accepted'] is! bool || reason is! String ||
          !RegExp(r'^[\x20-\x7e]{1,64}$').hasMatch(reason) ||
          elapsed is! num || !elapsed.isFinite ||
          elapsed < 0 || elapsed > 1200 ||
          (body['accepted'] == true && reason != 'matched')) {
        return const WakeVerifyReply(false, 'invalid_reply', 0);
      }
      return WakeVerifyReply(body['accepted'] == true, reason, elapsed.toInt());
    }

    try {
      return await exchange().timeout(timeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        return const WakeVerifyReply(false, 'timeout', 0);
      });
    } catch (_) {
      return const WakeVerifyReply(false, 'transport_error', 0);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void close() => _client.close();
}

class WakeVerifyReply {
  const WakeVerifyReply(this.accepted, this.reason, this.elapsedMs);
  final bool accepted;
  final String reason;
  final int elapsedMs;
}

String _requestId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
      '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

/// RIFF/WAVE header plus exactly 48,000 little-endian mono PCM16 samples.
Uint8List wav16k(Uint8List pcm) {
  if (pcm.length != 96000) throw ArgumentError.value(pcm.length, 'pcm');
  final out = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(out);
  void tag(int at, String value) => out.setRange(at, at + 4, ascii.encode(value));
  tag(0, 'RIFF');
  data.setUint32(4, out.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  out.setRange(44, out.length, pcm);
  return out;
}
