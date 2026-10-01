import 'dart:async';
import 'dart:typed_data';

/// A transport-neutral decision. The reason and duration are safe to report
/// in diagnostics; candidate audio and transcripts are never retained here.
class WakeVerificationDecision {
  const WakeVerificationDecision(this.accepted, this.reason, this.elapsedMs);
  final bool accepted;
  final String reason;
  final int elapsedMs;
}

/// Owns one pending decision. Rejection, timeout, cancellation, and exceptions
/// never start a turn. A late response cannot accept a newer candidate.
class WakeVerificationGate {
  WakeVerificationGate({this.timeout = const Duration(milliseconds: 1500)});

  final Duration timeout;
  int _generation = 0;

  void cancel() => _generation++;

  Future<WakeVerificationDecision> check(
    Uint8List? candidate,
    Future<WakeVerificationDecision> Function(Uint8List) verifier,
  ) async {
    final generation = ++_generation;
    if (candidate == null || candidate.length != 96000) {
      return const WakeVerificationDecision(false, 'candidate_unavailable', 0);
    }
    final clock = Stopwatch()..start();
    try {
      final decision = await verifier(candidate).timeout(timeout);
      if (generation != _generation) {
        return WakeVerificationDecision(false, 'stale', clock.elapsedMilliseconds);
      }
      return WakeVerificationDecision(
        decision.accepted,
        decision.reason,
        clock.elapsedMilliseconds,
      );
    } on TimeoutException {
      return WakeVerificationDecision(false, 'timeout', clock.elapsedMilliseconds);
    } catch (_) {
      return WakeVerificationDecision(false, 'error', clock.elapsedMilliseconds);
    }
  }
}
