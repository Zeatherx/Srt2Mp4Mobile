import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:srt2mp4_mobile/models/app_failure.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_backend.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_service.dart';
import 'package:srt2mp4_mobile/services/video_export_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native subtitle escaping, odd dimensions and public MediaStore export',
    (tester) async {
      final temporary = await getTemporaryDirectory();
      final directory = await temporary.createTemp(
        "audit ':[\u5b57\u5e55\u{1F3AC}]; ",
      );
      final video = File(p.join(directory.path, "video '[\u5b57].mp4"));
      final subtitles = await File(
        p.join(directory.path, "sub ':[\u5b57\u5e55];,.srt"),
      ).writeAsString('1\n00:00:00,000 --> 00:00:02,000\nHello \u5b57\u5e55\n');
      final encoder = FFmpegService();
      try {
        final source = await FFmpegKit.executeWithArguments([
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc=size=321x241:rate=10',
          '-t',
          '2',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv444p',
          video.path,
        ]);
        expect(ReturnCode.isSuccess(await source.getReturnCode()), isTrue);
        final output = await encoder
            .burn(
              video: video,
              subtitles: subtitles,
              duration: const Duration(seconds: 2),
            )
            .timeout(const Duration(seconds: 90));
        expect(output.path, contains('/Movies/srt2mp4/export/'));
        expect(output.isPublic, isTrue);
        expect(output.size, greaterThan(0));
        final readable = await FFmpegKitConfig.getSafParameterForRead(
          output.playbackUri.toString(),
        );
        final probe = await FFprobeKit.getMediaInformation(readable!);
        final stream = probe.getMediaInformation()!.getStreams().firstWhere(
          (stream) => stream.getType() == 'video',
        );
        expect(stream.getWidth(), 322);
        expect(stream.getHeight(), 242);
        await VideoExportService().discard(output);
      } on AppFailure catch (error) {
        fail('${error.message}\n${error.details}');
      } finally {
        await encoder.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'native cancellation stops the session and allows a retry',
    (tester) async {
      final backend = FFmpegBackend();
      final result = backend.execute([
        '-hide_banner',
        '-loglevel',
        'warning',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=30',
        '-f',
        'null',
        '-',
      ], onStatistics: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await backend.cancel();
      expect((await result.timeout(const Duration(seconds: 20))).exitCode, 255);
      final retry = await backend.execute(['-version'], onStatistics: (_) {});
      expect(retry.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
