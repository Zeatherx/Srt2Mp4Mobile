import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_failure.dart';
import '../models/encoding_progress.dart';
import '../models/exported_video.dart';
import 'ffmpeg_backend.dart';
import 'ffmpeg_paths.dart';
import 'video_export_service.dart';

class EncodingCancelled implements Exception {
  const EncodingCancelled();
  @override
  String toString() => 'Encoding cancelled.';
}

class FFmpegService {
  FFmpegService({
    FFmpegBackend? backend,
    VideoExportService? exports,
    Future<String> Function()? prepareFonts,
  }) : _backend = backend ?? FFmpegBackend(),
       _exports = exports ?? VideoExportService(),
       _fontLoader = prepareFonts;

  final FFmpegBackend _backend;
  final VideoExportService _exports;
  final Future<String> Function()? _fontLoader;
  final _progress = StreamController<EncodingProgress>.broadcast();
  Stream<EncodingProgress> get progress => _progress.stream;
  final _clock = Stopwatch();
  Timer? _ticker;
  bool _running = false;
  bool _publishing = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  double _fraction = 0;
  double _fps = 0;
  Completer<void>? _jobDone;
  Future<void>? _disposeFuture;
  String? _fontDirectory;

  void _emit() {
    if (_disposed) return;
    final elapsed = _clock.elapsed;
    final remaining = !_publishing && _fraction > 0 && _fraction < 1
        ? Duration(
            milliseconds: (elapsed.inMilliseconds * (1 - _fraction) / _fraction)
                .round(),
          )
        : null;
    _progress.add(
      EncodingProgress(
        fraction: _fraction,
        elapsed: elapsed,
        remaining: remaining,
        fps: _fps,
        exporting: _publishing,
      ),
    );
  }

  void _checkCancellation() {
    if (_cancelRequested) throw const EncodingCancelled();
  }

  Future<String> _prepareFonts() async {
    final loader = _fontLoader;
    if (loader != null) return loader();
    final prepared = _fontDirectory;
    if (prepared != null) return prepared;
    final support = await getApplicationSupportDirectory();
    final fonts = await Directory(
      p.join(support.path, 'subtitle_fonts'),
    ).create(recursive: true);
    for (final name in ['NotoSans-Regular.ttf', 'NotoSansCJKsc-Regular.otf']) {
      _checkCancellation();
      final data = await rootBundle.load('assets/fonts/$name');
      final target = File(p.join(fonts.path, name));
      // Recover from a zero-length or interrupted font write on an earlier run.
      if (await target.exists() &&
          await target.length() == data.lengthInBytes) {
        continue;
      }
      final pending = File('${target.path}.pending');
      try {
        await pending.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await pending.rename(target.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
    }
    return _fontDirectory = fonts.path;
  }

  Future<ExportedVideo> burn({
    required File video,
    required File subtitles,
    required Duration duration,
  }) async {
    if (_disposed) {
      throw const AppFailure('The encoder has been closed. Reopen the screen.');
    }
    if (_running) throw const AppFailure('An encoding is already running.');
    if (duration <= Duration.zero) {
      throw const AppFailure(
        'The video duration is invalid. Select the video again.',
      );
    }
    _running = true;
    _cancelRequested = false;
    _fraction = 0;
    _fps = 0;
    final done = Completer<void>();
    _jobDone = done;
    File? output;
    var success = false;
    try {
      _clock.reset();
      _emit();
      if (!await video.exists() || !await subtitles.exists()) {
        throw const AppFailure(
          'An input file is no longer available. Select your files again.',
        );
      }
      final fonts = await _prepareFonts();
      _checkCancellation();
      output = await _exports.createWorkingFile();
      _checkCancellation();
      _clock.start();
      // Statistics only update fields; at most four UI events per second.
      _ticker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _emit(),
      );
      final result = await _backend.execute(
        burnArguments(
          videoPath: video.path,
          subtitlePath: subtitles.path,
          fontDirectory: fonts,
          outputPath: output.path,
        ),
        onStatistics: (statistics) {
          if (_disposed || !_running || _publishing) return;
          final next = (statistics.timeMs / duration.inMilliseconds)
              .clamp(0.0, 0.99)
              .toDouble();
          if (next > _fraction) _fraction = next;
          _fps = statistics.fps.isFinite && statistics.fps >= 0
              ? statistics.fps
              : 0;
        },
      );
      if (result.exitCode == 255 || _cancelRequested) {
        throw const EncodingCancelled();
      }
      if (result.exitCode != 0) {
        throw AppFailure(
          'The video could not be encoded. Check that the MP4 and UTF-8 SRT are valid, then retry.',
          details: 'FFmpeg exit ${result.exitCode}: ${result.diagnostics}',
        );
      }
      if (!await output.exists() || await output.length() == 0) {
        throw const AppFailure(
          'The encoder produced an empty video. Please retry.',
        );
      }
      _checkCancellation();
      _publishing = true;
      _emit();
      final ExportedVideo exported;
      try {
        exported = await _exports.publish(output);
      } catch (_) {
        _checkCancellation();
        rethrow;
      }
      if (_cancelRequested) {
        await _exports.discard(exported);
        throw const EncodingCancelled();
      }
      _clock.stop();
      _publishing = false;
      _fraction = 1;
      _emit();
      success = true;
      return exported;
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _clock.stop();
      _publishing = false;
      try {
        if (output != null) {
          await _exports.releaseWorkingFile(output, succeeded: success);
        }
      } catch (error, stack) {
        debugPrint('Encoding temporary-file cleanup failed: $error\n$stack');
      } finally {
        _running = false;
        done.complete();
      }
    }
  }

  Future<void> cancel() async {
    if (!_running) return;
    _cancelRequested = true;
    // Native calls are bounded; a failed bridge call cannot strand dispose().
    try {
      if (_publishing) {
        await _exports.cancelPublication().timeout(const Duration(seconds: 3));
      } else {
        await _backend.cancel().timeout(const Duration(seconds: 4));
      }
    } catch (error) {
      throw AppFailure(
        'Cancellation could not be confirmed. Please try cancelling again.',
        details: error.toString(),
      );
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    try {
      await cancel();
    } catch (error) {
      debugPrint('Encoder cancellation during disposal: $error');
    }
    if (_running) await _jobDone?.future;
    await _progress.close();
  }
}
