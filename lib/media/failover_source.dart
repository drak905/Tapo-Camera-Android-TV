/// Live view of an owned camera found on the LAN: the local :8800 stream
/// first, the cloud relay when the local stream cannot start.
///
/// Spec decision (Tier 2 scenario 9): an unreachable local camera ends up on
/// the cloud relay within 2.5 s of the first attempt. Only failures BEFORE the
/// first byte switch; once video flows, errors reach the player (which
/// reconnects). Credential and session-limit refusals are not hidden behind
/// the relay: they are fatal and must not be retried on another path.
library;

import 'dart:async';
import 'dart:typed_data';

import 'media_errors.dart';
import 'media_source.dart';

/// Connect cap for the local :8800 attempt: a closed port on Windows takes
/// about 2 s to be refused, so the decision stays inside the 2.5 s budget.
const Duration kLocalConnectTimeout = Duration(milliseconds: 1200);

/// Errors that must reach the user instead of a failover.
bool isFatalLocalMediaError(Object error) =>
    error is MediaAuthException ||
    error is StreamLimitException ||
    error is StreamRefusedException ||
    error is BrokenSessionException;

class FailoverSource implements MediaSource {
  FailoverSource({
    required this.primary,
    required MediaSource Function()? fallback,
    this.budget = const Duration(milliseconds: 2500),
    this.onFailover,
  }) : _fallback = fallback;

  final MediaSource primary;
  final MediaSource Function()? _fallback;

  /// Time the primary gets to deliver its first byte.
  final Duration budget;

  /// Called once when the fallback is chosen, with the primary's error
  /// (a [TimeoutException] when the budget ran out).
  final void Function(Object reason)? onFailover;

  bool get hasFallback => _fallback != null;

  @override
  Stream<Uint8List> openTs() {
    late final StreamController<Uint8List> out;
    StreamSubscription<Uint8List>? sub;
    Timer? timer;
    var gotData = false;
    var switched = false;
    var cancelled = false;
    late final void Function(Object reason) doSwitch;

    void listenTo(Stream<Uint8List> stream, {required bool isPrimary}) {
      sub = stream.listen(
        (chunk) {
          if (isPrimary && switched) return;
          if (!gotData) {
            gotData = true;
            timer?.cancel();
          }
          out.add(chunk);
        },
        onError: (Object e, StackTrace s) {
          if (isPrimary && switched) return;
          if (isPrimary && !gotData) {
            timer?.cancel();
            if (!isFatalLocalMediaError(e) && _fallback != null) {
              doSwitch(e);
              return;
            }
          }
          if (!out.isClosed) out.addError(e, s);
        },
        onDone: () {
          if (isPrimary && switched) return;
          if (isPrimary && !gotData && _fallback != null) {
            timer?.cancel();
            doSwitch(const MediaException('local stream ended before any video'));
            return;
          }
          if (!out.isClosed) unawaited(out.close());
        },
        cancelOnError: false,
      );
    }

    doSwitch = (Object reason) {
      if (switched || cancelled) return;
      switched = true;
      final old = sub;
      sub = null;
      unawaited(old?.cancel());
      onFailover?.call(reason);
      final MediaSource next;
      try {
        next = _fallback!();
      } catch (e, s) {
        if (!out.isClosed) {
          out.addError(e, s);
          unawaited(out.close());
        }
        return;
      }
      listenTo(next.openTs(), isPrimary: false);
    };

    out = StreamController<Uint8List>(
      onListen: () {
        listenTo(primary.openTs(), isPrimary: true);
        if (_fallback != null) {
          timer = Timer(budget, () {
            if (!gotData) doSwitch(TimeoutException('local stream did not start', budget));
          });
        }
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        cancelled = true;
        timer?.cancel();
        final s = sub;
        sub = null;
        await s?.cancel();
      },
    );
    return out.stream;
  }

}
