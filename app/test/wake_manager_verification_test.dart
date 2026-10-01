import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/wake_word/engine.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_word_manager.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_verifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine extends WakeWordEngine {
  DetectionCallback? detection;
  bool isRunning = false;
  bool candidateEnabled = false;
  int clears = 0;
  int resumes = 0;
  Uint8List? candidate = Uint8List(96000);
  String? handoffError;

  @override
  Set<WakeWordEngineType> get supportedEngines => {WakeWordEngineType.vsWakeWord};
  @override
  bool get running => isRunning;
  @override
  set captureWakeCandidate(bool enabled) => candidateEnabled = enabled;
  @override
  Uint8List? takeWakeCandidate() {
    final result = candidate;
    candidate = null;
    return result;
  }
  @override
  void clearWakeHandoff() => clears++;
  @override
  String? get wakeHandoffError => handoffError;
  @override
  Future<void> start({required WakeWordConfig config,
      required DetectionCallback onDetection,
      StopDetectionCallback? onStopDetection,
      EngineFailureCallback? onFailure}) async {
    isRunning = true;
    detection = onDetection;
  }
  @override
  Future<void> stop() async => isRunning = false;
  @override
  Future<void> resumeDetection() async => resumes++;

  Future<void> fire() => detection!(const WakeWordModelRef(
      id: 'hey_luna', wakeWord: 'Hey Luna', manifestUrl: 'http://ha/model'));
}

class _Verifier extends WakeVerifier {
  Future<WakeVerifyReply> Function()? answer;
  int calls = 0;
  @override
  Future<WakeVerifyReply> verify({required String homeAssistantUrl,
      required String token, required String endpointId,
      required Uint8List pcm}) {
    calls++;
    expect(homeAssistantUrl, 'http://ha.example:8123');
    expect(token, 'test-token');
    expect(endpointId, 'voice-garage');
    expect(pcm.length, 96000);
    return answer!();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late WakeWordManager manager;
  late _Engine engine;
  late _Verifier verifier;
  late List<WakeWordDetected> events;
  var screenPokes = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    bus = EventBus();
    commands = CommandRegistry(Logger());
    settings = SettingsManager(bus, commands, Logger());
    await settings.init();
    engine = _Engine();
    verifier = _Verifier();
    manager = WakeWordManager(bus, commands, Logger(), settings,
        engines: {WakeWordEngineType.vsWakeWord: engine}, verifier: verifier);
    await manager.init();
    events = [];
    bus.on<WakeWordDetected>().listen(events.add);
    screenPokes = 0;
    commands.register(Command(name: 'screenOn', description: 'test',
        handler: (_) async {
          screenPokes++;
          return const CommandResult.ok();
        }));
    await settings.set(defs.haUrl, 'http://ha.example:8123');
    await settings.set(defs.haToken, 'test-token');
    await settings.set(defs.wakeWordVerificationEndpointId, 'voice-garage');
    await commands.execute('setWakeWordConfig', const {
      'engine': 'vsWakeWord',
      'models': [{'id': 'hey_luna', 'wakeWord': 'Hey Luna',
        'manifestUrl': 'http://ha.example:8123/model'}],
    });
  });

  tearDown(() async {
    await manager.dispose();
    await bus.dispose();
  });

  test('disabled pilot retains ordinary wake behavior', () async {
    expect(engine.candidateEnabled, isFalse);
    await engine.fire();
    await Future<void>.delayed(Duration.zero);
    expect(verifier.calls, 0);
    expect(screenPokes, 1);
    expect(events, hasLength(1));
  });

  test('rejected pilot is silent and re-arms', () async {
    await settings.set(defs.wakeWordVerificationEnabled, true);
    await Future<void>.delayed(Duration.zero);
    verifier.answer = () async => const WakeVerifyReply(false, 'no_match', 25);
    await engine.fire();
    expect(engine.candidateEnabled, isTrue);
    expect(verifier.calls, 1);
    expect(screenPokes, 0);
    expect(events, isEmpty);
    expect(engine.clears, 1);
    expect(engine.resumes, greaterThan(0));
    expect(manager.listening, isTrue);
    expect((manager.describeState()['wakeVerification'] as Map)['reason'], 'no_match');
  });

  test('acceptance delays screen and event until verifier responds', () async {
    await settings.set(defs.wakeWordVerificationEnabled, true);
    await Future<void>.delayed(Duration.zero);
    final pending = Completer<WakeVerifyReply>();
    verifier.answer = () => pending.future;
    final detection = engine.fire();
    await Future<void>.delayed(Duration.zero);
    expect(screenPokes, 0);
    expect(events, isEmpty);
    pending.complete(const WakeVerifyReply(true, 'matched', 30));
    await detection;
    await Future<void>.delayed(Duration.zero);
    expect(screenPokes, 1);
    expect(events, hasLength(1));
  });

  test('manual page action cancels a pending verification', () async {
    await settings.set(defs.wakeWordVerificationEnabled, true);
    await Future<void>.delayed(Duration.zero);
    final pending = Completer<WakeVerifyReply>();
    verifier.answer = () => pending.future;
    final detection = engine.fire();
    await Future<void>.delayed(Duration.zero);
    manager.setActive(false);
    pending.complete(const WakeVerifyReply(true, 'matched', 30));
    await detection;
    expect(screenPokes, 0);
    expect(events, isEmpty);
  });

  test('accepted result still fails closed if command handoff overflowed', () async {
    await settings.set(defs.wakeWordVerificationEnabled, true);
    await Future<void>.delayed(Duration.zero);
    verifier.answer = () async {
      engine.handoffError = 'Wake audio handoff exceeded the buffer';
      return const WakeVerifyReply(true, 'matched', 30);
    };
    await engine.fire();
    expect(screenPokes, 0);
    expect(events, isEmpty);
    expect(engine.clears, 1);
    expect(manager.listening, isTrue);
    expect((manager.describeState()['wakeVerification'] as Map)['reason'],
        'handoff_overflow');
  });
}
