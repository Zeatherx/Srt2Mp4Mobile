import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/session_state.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import '../models/app_failure.dart';

class EncoderStatistics {
  const EncoderStatistics(this.timeMs, this.fps);
  final int timeMs;
  final double fps;
}

class EncoderResult {
  const EncoderResult(this.exitCode, {this.diagnostics = ''});
  final int? exitCode;
  final String diagnostics;
}

/// Owns exactly one native session. Session-local callbacks cannot steal
/// another encoder's statistics or be reset by another service's dispose().
class FFmpegBackend {
  // The pinned SDK retains callback records. Static routers ensure these do
  // not retain completed job/service/widget object graphs.
  static final _active = <int, _EncodingEvents>{};
  static void _onComplete(FFmpegSession session) =>
      _active[session.getSessionId()]?.finish();
  static void _onStatistics(Statistics statistics) =>
      _active[statistics.getSessionId()]?.onStatistics(
        EncoderStatistics(statistics.getTime(), statistics.getVideoFps()),
      );
  static void _onLog(Log log) {
    final events = _active[log.getSessionId()];
    if (events == null) return;
    final combined = '${events.diagnostics}${log.getMessage()}';
    events.diagnostics = combined.length <= 4000
        ? combined
        : combined.substring(combined.length - 4000);
  }

  FFmpegSession? _session;
  bool _cancelRequested = false;
  bool _running = false;
  bool _cancelTimedOut = false;
  Timer? _cancelDeadline;
  Completer<void>? _completed;

  Future<EncoderResult> execute(
    List<String> arguments, {
    required void Function(EncoderStatistics) onStatistics,
  }) async {
    if (_running) throw const AppFailure('An encoding is already running.');
    _running = true;
    _cancelRequested = false;
    _cancelTimedOut = false;
    _cancelDeadline = null;
    final completed = Completer<void>();
    _completed = completed;
    final events = _EncodingEvents(completed, onStatistics);
    Object? bridgeFailure;
    var polling = false;
    Timer? poll;
    void finish() {
      if (!completed.isCompleted) completed.complete();
    }

    try {
      final session = await FFmpegSession.create(
        arguments,
        _onComplete,
        _onLog,
        _onStatistics,
      ).timeout(const Duration(seconds: 15));
      _session = session;
      if (session.getSessionId() == null) {
        throw const AppFailure(
          'The encoder could not create a session. Please retry.',
        );
      }
      _active[session.getSessionId()!] = events;
      if (_cancelRequested) return const EncoderResult(255);
      await FFmpegKitConfig.asyncFFmpegExecute(
        session,
      ).timeout(const Duration(seconds: 15));
      if (_cancelRequested) await cancel();
      // A terminal session remains observable even if its completion event was
      // lost during a platform/lifecycle transition.
      poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (polling || completed.isCompleted) return;
        polling = true;
        try {
          final state = await session.getState().timeout(
            const Duration(seconds: 5),
          );
          if (state == SessionState.completed || state == SessionState.failed) {
            finish();
          }
        } catch (error) {
          bridgeFailure = error;
          finish();
        } finally {
          polling = false;
        }
      });
      await completed.future;
      if (_cancelTimedOut) {
        bridgeFailure = TimeoutException('Cancellation was not acknowledged');
        throw const AppFailure(
          'The device did not confirm cancellation. Reopen the app before encoding again.',
        );
      }
      if (bridgeFailure != null) {
        throw const AppFailure(
          'Communication with the encoder was interrupted. Please retry.',
        );
      }
      if (_cancelRequested) {
        return EncoderResult(255, diagnostics: events.diagnostics);
      }
      final code = await session.getReturnCode().timeout(
        const Duration(seconds: 5),
      );
      return EncoderResult(code?.getValue(), diagnostics: events.diagnostics);
    } catch (error) {
      if (error is AppFailure) rethrow;
      throw AppFailure(
        'The video encoder could not complete the operation. Please retry.',
        details: error.toString(),
      );
    } finally {
      _active.remove(_session?.getSessionId());
      poll?.cancel();
      _cancelDeadline?.cancel();
      // On bridge failures/start timeouts, stop the known session best-effort.
      if ((!completed.isCompleted && _session != null) ||
          bridgeFailure != null) {
        final id = _session?.getSessionId();
        if (id != null) {
          try {
            await FFmpegKit.cancel(id).timeout(const Duration(seconds: 3));
          } catch (_) {
            /* The job's recoverable error is already being reported. */
          }
        }
      }
      _session = null;
      _completed = null;
      _running = false;
    }
  }

  Future<void> cancel() async {
    if (!_running) return;
    _cancelRequested = true;
    _cancelDeadline ??= Timer(const Duration(seconds: 10), () {
      _cancelTimedOut = true;
      final completed = _completed;
      if (completed != null && !completed.isCompleted) completed.complete();
    });
    final id = _session?.getSessionId();
    if (id != null) {
      await FFmpegKit.cancel(id).timeout(const Duration(seconds: 3));
    }
  }
}

class _EncodingEvents {
  _EncodingEvents(this.completed, this.onStatistics);
  final Completer<void> completed;
  final void Function(EncoderStatistics) onStatistics;
  String diagnostics = '';
  void finish() {
    if (!completed.isCompleted) completed.complete();
  }
}
