import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_container.dart';
import '../managers/settings/definitions.dart' as defs;
import '../managers/wake_word/engine.dart';
import '../managers/wake_word/training_clips.dart';
import 'wake_audio_player.dart';

class WakeTrainingTile extends StatelessWidget {
  const WakeTrainingTile({super.key, required this.container});
  final AppContainer container;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.mic_outlined),
    title: const Text('Record wake-word examples'),
    subtitle: const Text('Collect labeled audio for a future Hey Luna model.'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => showDialog<void>(
      context: context,
      builder: (_) => _WakeTrainingDialog(container: container),
    ),
  );
}

class _WakeTrainingDialog extends StatefulWidget {
  const _WakeTrainingDialog({required this.container});
  final AppContainer container;

  @override
  State<_WakeTrainingDialog> createState() => _WakeTrainingDialogState();
}

class _WakeTrainingDialogState extends State<_WakeTrainingDialog> {
  static const captureTime = Duration(seconds: 4);
  late final _store = WakeTrainingClips(
    sourceName: widget.container.device.deviceName,
    sourceId: widget.container.settings.get(defs.sendspinClientId),
  );
  late final WakeAudioPlayer _player;
  Timer? _timer;
  List<TrainingClip> _saved = const [];
  Uint8List? _draft;
  TrainingLabel _label = TrainingLabel.heyLuna;
  int _secondsLeft = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = WakeAudioPlayer(widget.container);
    widget.container.wakeWord.startTest();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final clips = await _store.list();
      if (mounted) setState(() => _saved = clips);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read saved clips: $e');
    }
  }

  Future<void> _record() async {
    if (_busy || _secondsLeft > 0) return;
    await _player.stop();
    if (!widget.container.wakeWord.beginTrainingClip()) {
      setState(
        () => _error =
            'Wake microphone is unavailable. Check Voice Satellite and try again.',
      );
      return;
    }
    setState(() {
      _draft = null;
      _error = null;
      _secondsLeft = captureTime.inSeconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft > 1) {
        setState(() => _secondsLeft--);
        return;
      }
      timer.cancel();
      final pcm = widget.container.wakeWord.recentAudio(
        WakeWordEngine.recentAudioLimit,
      );
      setState(() {
        _secondsLeft = 0;
        if (pcm == null || pcm.length < 16000 * 2 * 3) {
          _error =
              'The microphone stopped before the clip finished. Try again.';
        } else {
          _draft = pcm;
        }
      });
    });
  }

  Future<void> _save() async {
    final pcm = _draft;
    if (pcm == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.save(_label, pcm);
      if (!mounted) return;
      setState(() => _draft = null);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save clip: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_saved.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bundle = await _store.exportBundle();
      await Share.shareXFiles(
        [XFile(bundle.path, mimeType: 'application/zip')],
        subject: 'Hey Luna training clips',
        text:
            'Labeled 16 kHz mono recordings from this Portal. Filenames identify Hey Luna and other audio.',
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not share clips: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _player.dispose();
    widget.container.wakeWord.stopTest();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Hey Luna training clips',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Wake detection is paused while this screen is open. Only audio recorded with the button is saved. Speak after tapping Record.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _secondsLeft > 0 || _busy ? null : _record,
              icon: const Icon(Icons.fiber_manual_record),
              label: Text(
                _secondsLeft > 0
                    ? 'Recording… $_secondsLeft s'
                    : 'Record 4 seconds',
              ),
            ),
            if (_draft != null) ...[
              const SizedBox(height: 12),
              Text(
                'Review ${(_draft!.length / 32000).toStringAsFixed(1)} seconds before saving.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Hey Luna'),
                    selected: _label == TrainingLabel.heyLuna,
                    onSelected: (_) =>
                        setState(() => _label = TrainingLabel.heyLuna),
                  ),
                  ChoiceChip(
                    label: const Text('Other speech or background'),
                    selected: _label == TrainingLabel.otherAudio,
                    onSelected: (_) =>
                        setState(() => _label = TrainingLabel.otherAudio),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _player.play('draft', pcm: _draft),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Replay'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _draft = null),
                    child: const Text('Discard'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Save labeled clip'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const Divider(height: 28),
            Text('Saved on this Portal: ${_saved.length}'),
            for (final clip in _saved)
              ListTile(
                dense: true,
                title: Text(
                  clip.label == TrainingLabel.heyLuna
                      ? 'Hey Luna'
                      : 'Other audio',
                ),
                subtitle: Text(clip.file.uri.pathSegments.last),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete clip',
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            await _store.delete(clip);
                            await _refresh();
                          } catch (e) {
                            if (mounted) {
                              setState(
                                () => _error = 'Could not delete clip: $e',
                              );
                            }
                          }
                        },
                ),
                onTap: () => _player.play(clip.file.path, file: clip.file),
              ),
            OutlinedButton.icon(
              onPressed: _saved.isEmpty || _busy ? null : _share,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Export all clips as ZIP'),
            ),
          ],
        ),
      ),
    ),
  );
}
