import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/models/app_failure.dart';
import 'package:srt2mp4_mobile/models/encoding_progress.dart';
import 'package:srt2mp4_mobile/models/exported_video.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_backend.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_service.dart';
import 'package:srt2mp4_mobile/services/video_export_service.dart';

class _Backend extends FFmpegBackend {
  int calls = 0;
  int exitCode = 0;
  final started = Completer<void>();
  Completer<EncoderResult>? pending;
  void Function(EncoderStatistics)? statistics;
  @override
  Future<EncoderResult> execute(
    List<String> arguments, {
    required void Function(EncoderStatistics) onStatistics,
  }) async {
    calls++;
    statistics = onStatistics;
    await File(arguments.last).writeAsBytes([1, 2, 3, 4]);
    if (!started.isCompleted) started.complete();
    return pending?.future ??
        EncoderResult(exitCode, diagnostics: 'private diagnostic');
  }

  @override
  Future<void> cancel() async {
    final waiting = pending;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(const EncoderResult(255));
    }
  }
}

class _Exports extends VideoExportService {
  _Exports(this.directory) : super(isAndroid: false);
  final Directory directory;
  int released = 0;
  int published = 0;
  int discarded = 0;
  bool cleanupThrows = false;
  Completer<ExportedVideo>? publication;
  final publicationStarted = Completer<void>();
  @override
  Future<File> createWorkingFile() async =>
      File('${directory.path}/output.mp4');
  @override
  Future<ExportedVideo> publish(File workingFile) async {
    published++;
    if (!publicationStarted.isCompleted) publicationStarted.complete();
    return publication?.future ??
        ExportedVideo(
          path: workingFile.path,
          playbackUri: workingFile.uri,
          size: 4,
        );
  }

  @override
  Future<void> releaseWorkingFile(File file, {required bool succeeded}) async {
    released++;
    if (cleanupThrows) {
      throw const FileSystemException('Injected cleanup failure');
    }
    if (!succeeded && await file.exists()) await file.delete();
  }

  @override
  Future<void> discard(ExportedVideo video) async {
    discarded++;
  }

  @override
  Future<void> cancelPublication() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File video;
  late File srt;
  late _Backend backend;
  late _Exports exports;
  late FFmpegService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('encoder_audit_');
    video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
    srt = await File(
      '${directory.path}/subtitles.srt',
    ).writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHello');
    backend = _Backend();
    exports = _Exports(directory);
    service = FFmpegService(
      backend: backend,
      exports: exports,
      prepareFonts: () async => directory.path,
    );
  });
  tearDown(() async {
    await service.dispose();
    await directory.delete(recursive: true);
  });
  Future<ExportedVideo> burn() => service.burn(
    video: video,
    subtitles: srt,
    duration: const Duration(seconds: 2),
  );

  test('non-zero exit stays recoverable even when cleanup throws', () async {
    backend.exitCode = 1;
    exports.cleanupThrows = true;
    await expectLater(burn(), throwsA(isA<AppFailure>()));
    expect(exports.published, 0);
    backend.exitCode = 0;
    exports.cleanupThrows = false;
    expect((await burn()).size, 4);
    expect(backend.calls, 2);
  });

  test('cancellation before session creation never starts FFmpeg', () async {
    final fonts = Completer<String>();
    await service.dispose();
    service = FFmpegService(
      backend: backend,
      exports: exports,
      prepareFonts: () => fonts.future,
    );
    final result = burn();
    final expectation = expectLater(result, throwsA(isA<EncodingCancelled>()));
    await service.cancel();
    fonts.complete(directory.path);
    await expectation;
    expect(backend.calls, 0);
  });

  test('cancels an active encoder and removes its incomplete output', () async {
    backend.pending = Completer<EncoderResult>();
    final result = burn();
    final expectation = expectLater(result, throwsA(isA<EncodingCancelled>()));
    await backend.started.future;
    await service.cancel();
    await expectation;
    expect(exports.published, 0);
    expect(await File('${directory.path}/output.mp4').exists(), isFalse);
  });

  test(
    'rolls back an export if cancellation arrives while publishing',
    () async {
      exports.publication = Completer<ExportedVideo>();
      final result = burn();
      final expectation = expectLater(
        result,
        throwsA(isA<EncodingCancelled>()),
      );
      await exports.publicationStarted.future;
      await service.cancel();
      exports.publication!.complete(
        ExportedVideo(
          path: '/Movies/srt2mp4/export/video.mp4',
          playbackUri: Uri.parse('content://media/video/1'),
          size: 4,
          isPublic: true,
        ),
      );
      await expectation;
      expect(exports.discarded, 1);
    },
  );

  test(
    'statistics bursts are coalesced and invalid FPS is sanitized',
    () async {
      backend.pending = Completer<EncoderResult>();
      final progress = <EncodingProgress>[];
      final subscription = service.progress.listen(progress.add);
      final result = burn();
      await backend.started.future;
      for (var i = 0; i < 10000; i++) {
        backend.statistics!(EncoderStatistics(i, double.nan));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(progress.length, lessThan(5));
      expect(progress.last.fraction, 0.99);
      expect(progress.last.fps, 0);
      backend.pending!.complete(const EncoderResult(0));
      await result;
      await subscription.cancel();
    },
  );

  test('dispose is idempotent and waits for cancellation cleanup', () async {
    backend.pending = Completer<EncoderResult>();
    final result = burn();
    final expectation = expectLater(result, throwsA(isA<EncodingCancelled>()));
    await backend.started.future;
    await Future.wait([service.dispose(), service.dispose()]);
    await expectation;
    expect(exports.released, 1);
  });
}
