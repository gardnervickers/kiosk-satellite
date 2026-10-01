import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:kiosk_satellite/managers/wake_word/training_clips.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'saves explicit labels and source metadata as portable WAV pairs',
    () async {
      final dir = await Directory.systemTemp.createTemp('wake-training-test-');
      addTearDown(() => dir.delete(recursive: true));
      final clips = WakeTrainingClips(
        sourceName: 'Garage Portal',
        sourceId: 'portal-d-player',
        directory: () async => dir,
        exportDirectory: () async => dir,
      );
      final pcm = Uint8List(16000 * 2 * 4);
      final positive = await clips.save(TrainingLabel.heyLuna, pcm);
      final negative = await clips.save(TrainingLabel.otherAudio, pcm);
      final listed = await clips.list();
      expect(listed.length, 2);
      expect(positive.file.path, contains('Garage-Portal_hey_luna_'));
      expect(negative.file.path, contains('Garage-Portal_other_audio_'));
      expect((await positive.file.readAsBytes()).length, pcm.length + 44);
      final meta = jsonDecode(
        await File('${positive.file.path}.json').readAsString(),
      );
      expect(meta['source_name'], 'Garage Portal');
      expect(meta['source_id'], 'portal-d-player');
      expect(meta['label'], 'hey_luna');
      expect(meta['sample_rate'], 16000);
      expect(meta['duration_ms'], 4000);
      final bundle = await clips.exportBundle();
      addTearDown(() => bundle.delete());
      final archived = ZipDecoder().decodeBytes(await bundle.readAsBytes());
      expect(archived.length, 4);
      expect(
        archived.files.map((f) => f.name),
        contains(positive.file.uri.pathSegments.last),
      );
      await clips.delete(positive);
      expect(await positive.file.exists(), false);
      expect(await File('${positive.file.path}.json').exists(), false);
      expect((await clips.list()).single.label, TrainingLabel.otherAudio);
    },
  );

  test('rejects empty or oversized captures', () async {
    final dir = await Directory.systemTemp.createTemp('wake-training-test-');
    addTearDown(() => dir.delete(recursive: true));
    final clips = WakeTrainingClips(
      sourceName: 'Garage Portal',
      directory: () async => dir,
    );
    await expectLater(
      clips.save(TrainingLabel.heyLuna, Uint8List(0)),
      throwsArgumentError,
    );
    await expectLater(
      clips.save(TrainingLabel.heyLuna, Uint8List(16000 * 2 * 11)),
      throwsArgumentError,
    );
    expect(await clips.list(), isEmpty);
  });
}
