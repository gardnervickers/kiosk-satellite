import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/wake_word/isolate_engine.dart';

Uint8List _chunk(int value, [int samples = 1280]) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, value, Endian.little);
  }
  return bytes;
}

int _sample(Uint8List bytes, int index) =>
    ByteData.sublistView(bytes).getInt16(index * 2, Endian.little);

void main() {
  test('candidate is exactly three seconds ending at detector sample', () {
    final history = WakeCandidateBuffer();
    for (var i = 0; i < 45; i++) history.add(_chunk(i + 1));
    const detectionSample = 40 * 1280;
    final candidate = history.at(detectionSample)!;
    expect(candidate.length, 96000);
    // 48,000 samples before detection: 37 full chunks and 640 samples.
    expect(_sample(candidate, 0), 3);
    expect(_sample(candidate, 639), 3);
    expect(_sample(candidate, 640), 4);
    expect(_sample(candidate, 47999), 40);
    expect(candidate.contains(41), isFalse);
  });

  test('startup prefix is padded and a stale detection fails closed', () {
    final history = WakeCandidateBuffer();
    history.add(_chunk(123, 1600));
    final candidate = history.at(1600)!;
    expect(candidate.length, 96000);
    expect(_sample(candidate, 46399), 0);
    expect(_sample(candidate, 46400), 123);
    expect(_sample(candidate, 47999), 123);
    for (var i = 0; i < 60; i++) history.add(_chunk(i));
    expect(history.at(1600), isNull);
    history.clear();
    expect(history.at(0), Uint8List(96000));
  });

  test('enabling capture on a running microphone keeps its sample clock', () {
    final history = WakeCandidateBuffer(initialSample: 1000000);
    history.add(_chunk(7));
    history.add(_chunk(8));
    final candidate = history.at(1000000 + 1280)!;
    expect(candidate.length, 96000);
    expect(_sample(candidate, 47999), 7);
    expect(candidate.contains(8), isFalse);
  });
}
