import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_verification_gate.dart';

void main() {
  final candidate = Uint8List(96000);

  test('accepts only a valid candidate and affirmative response', () async {
    final gate = WakeVerificationGate();
    final accepted = await gate.check(
      candidate,
      (_) async => const WakeVerificationDecision(true, 'match', 12),
    );
    expect(accepted.accepted, isTrue);
    expect(accepted.reason, 'match');
    final missing = await gate.check(null, (_) async =>
        const WakeVerificationDecision(true, 'match', 12));
    expect(missing.accepted, isFalse);
    expect(missing.reason, 'candidate_unavailable');
  });

  test('timeout rejects and a late accept never changes the decision', () async {
    final gate = WakeVerificationGate(timeout: const Duration(milliseconds: 10));
    final response = Completer<WakeVerificationDecision>();
    final decision = await gate.check(candidate, (_) => response.future);
    expect(decision.accepted, isFalse);
    expect(decision.reason, 'timeout');
    response.complete(const WakeVerificationDecision(true, 'match', 30));
    await response.future;
    expect(decision.accepted, isFalse);
  });

  test('cancellation and a newer request invalidate an old response', () async {
    final gate = WakeVerificationGate();
    final response = Completer<WakeVerificationDecision>();
    final first = gate.check(candidate, (_) => response.future);
    gate.cancel();
    response.complete(const WakeVerificationDecision(true, 'match', 1));
    expect((await first).reason, 'stale');

    final older = Completer<WakeVerificationDecision>();
    final pending = gate.check(candidate, (_) => older.future);
    final newer = await gate.check(candidate, (_) async =>
        const WakeVerificationDecision(false, 'no_match', 1));
    older.complete(const WakeVerificationDecision(true, 'match', 1));
    expect(newer.reason, 'no_match');
    expect((await pending).reason, 'stale');
  });
}
