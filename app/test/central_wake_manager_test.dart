import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/core/permissions.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/wake_word/central_wake_engine.dart';
import 'package:kiosk_satellite/managers/wake_word/engine.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_word_manager.dart';

class _LocalEngine extends WakeWordEngine {
  int starts = 0;
  @override
  bool get running => starts > 0;
  @override
  Set<WakeWordEngineType> get supportedEngines => {
    WakeWordEngineType.vsWakeWord,
  };
  @override
  Future<void> start({
    required WakeWordConfig config,
    required DetectionCallback onDetection,
    StopDetectionCallback? onStopDetection,
    EngineFailureCallback? onFailure,
  }) async {
    starts++;
  }

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'central opt-in never starts the local classifier and privacy closes capture',
    () async {
      SharedPreferences.setMockInitialValues({});
      final bus = EventBus();
      final commands = CommandRegistry(Logger());
      final settings = SettingsManager(bus, commands, Logger());
      await settings.init();
      await settings.set(defs.wakeWordCentralEnabled, true);
      await settings.set(defs.haUrl, 'http://ha.example:8123');
      await settings.set(defs.haToken, 'test-token');
      await settings.set(defs.wakeWordVerificationEndpointId, 'voice-garage');
      final mic = StreamController<Uint8List>.broadcast();
      final pending = Completer<WebSocket>();
      final central = CentralWakeEngine(
        Logger(),
        homeAssistantUrl: () => settings.get(defs.haUrl),
        token: () => settings.get(defs.haToken),
        endpointId: () => settings.get(defs.wakeWordVerificationEndpointId),
        onAvailability: (_) {},
        mic: () => mic.stream,
        micPermission: () async => PermissionOutcome.granted,
        connect: (_, _) => pending.future,
      );
      final local = _LocalEngine();
      final manager = WakeWordManager(
        bus,
        commands,
        Logger(),
        settings,
        engines: {WakeWordEngineType.vsWakeWord: local},
        centralEngine: central,
      );
      try {
        await manager.init();
        await manager.configure(
          const WakeWordConfig(
            engine: WakeWordEngineType.vsWakeWord,
            models: [
              WakeWordModelRef(
                id: 'hey_luna',
                wakeWord: 'Hey Luna',
                manifestUrl: 'unused',
              ),
            ],
          ),
        );
        expect(local.starts, 0);
        expect(central.running, true);
        expect(mic.hasListener, true);
        expect(manager.available, true); // no browser fallback on network loss
        expect(manager.describeState()['status'], 'unavailable');
        await manager.release('muted');
        expect(central.running, false);
        expect(mic.hasListener, false);
      } finally {
        await manager.dispose();
        await mic.close();
        await bus.dispose();
      }
    },
  );
}
