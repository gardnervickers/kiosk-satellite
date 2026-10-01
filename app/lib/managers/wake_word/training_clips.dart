import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

import 'pcm16.dart';
import '../settings/export_filename.dart';

enum TrainingLabel { heyLuna, otherAudio }

class TrainingClip {
  const TrainingClip(this.file, this.label);
  final File file;
  final TrainingLabel label;
}

/// Explicitly recorded, device-local examples. No background recording or
/// automatic upload; filenames carry labels when shared for training.
class WakeTrainingClips {
  WakeTrainingClips({
    required this.sourceName,
    this.sourceId = '',
    Future<Directory> Function()? directory,
    Future<Directory> Function()? exportDirectory,
  }) : _directory = directory ?? _defaultDirectory,
       _exportDirectory = exportDirectory ?? getTemporaryDirectory;

  static const maxClips = 200;
  final String sourceName;
  final String sourceId;
  final Future<Directory> Function() _directory;
  final Future<Directory> Function() _exportDirectory;
  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/wake_training',
  );

  Future<Directory> _dir() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<TrainingClip>> list() async {
    final dir = await _dir();
    final clips = <TrainingClip>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final label = name.contains('_hey_luna_')
          ? TrainingLabel.heyLuna
          : name.contains('_other_audio_')
          ? TrainingLabel.otherAudio
          : null;
      if (label != null && name.endsWith('.wav')) {
        clips.add(TrainingClip(entity, label));
      }
    }
    clips.sort((a, b) => b.file.path.compareTo(a.file.path));
    return clips;
  }

  Future<TrainingClip> save(TrainingLabel label, Uint8List pcm) async {
    if (pcm.length < 16000 * 2 ||
        pcm.length > 16000 * 2 * 10 ||
        pcm.length.isOdd) {
      throw ArgumentError('Training clip must contain 1–10 seconds of PCM16');
    }
    final prefix = label == TrainingLabel.heyLuna ? 'hey_luna' : 'other_audio';
    final dir = await _dir();
    if ((await list()).length >= maxClips) {
      throw StateError(
        'Training collection is full. Share or delete clips first.',
      );
    }
    final source = exportNameSlug(sourceName).isEmpty
        ? 'unknown-device'
        : exportNameSlug(sourceName);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    var suffix = 0;
    File file;
    do {
      file = File('${dir.path}/${source}_${prefix}_${stamp}_${suffix++}.wav');
    } while (await file.exists());
    final pending = File('${file.path}.part');
    try {
      await pending.writeAsBytes(pcm16Wav(pcm), flush: true);
      await pending.rename(file.path);
      await File('${file.path}.json').writeAsString(
        jsonEncode({
          'source_name': sourceName,
          'source_id': sourceId,
          'recorded_at': DateTime.now().toUtc().toIso8601String(),
          'label': label == TrainingLabel.heyLuna ? 'hey_luna' : 'other_audio',
          'sample_rate': 16000,
          'channels': 1,
          'sample_format': 'pcm_s16le',
          'duration_ms': pcm.length ~/ 32,
        }),
        flush: true,
      );
    } catch (_) {
      if (await pending.exists()) await pending.delete();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return TrainingClip(file, label);
  }

  Future<void> delete(TrainingClip clip) async {
    final dir = await _dir();
    if (clip.file.parent.path != dir.path) throw ArgumentError('Unknown clip');
    await clip.file.delete();
    final metadata = File('${clip.file.path}.json');
    if (await metadata.exists()) await metadata.delete();
  }

  /// One portable export for all examples, with WAV and metadata pairs.
  Future<File> exportBundle() async {
    final clips = await list();
    if (clips.isEmpty) throw StateError('No training clips to export');
    final archive = Archive();
    for (final clip in clips) {
      for (final file in [clip.file, File('${clip.file.path}.json')]) {
        if (!await file.exists()) throw StateError('Missing clip metadata');
        final bytes = await file.readAsBytes();
        archive.addFile(
          ArchiveFile(file.uri.pathSegments.last, bytes.length, bytes),
        );
      }
    }
    final slug = exportNameSlug(sourceName);
    final destination = File(
      '${(await _exportDirectory()).path}/hey-luna-training-${slug.isEmpty ? 'portal' : slug}.zip',
    );
    await destination.writeAsBytes(
      ZipEncoder().encodeBytes(archive),
      flush: true,
    );
    return destination;
  }
}
