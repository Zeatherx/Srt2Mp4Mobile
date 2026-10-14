import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/models/app_failure.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  late List<MethodCall> calls;
  late bool validSession;
  var nextId = 1;
  setUp(() {
    calls = [];
    validSession = true;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getLogLevel':
          return 24;
        case 'getPlatform':
          return 'android';
        case 'getArch':
          return 'x86_64';
        case 'getPackageName':
          return 'full-gpl';
        case 'getExternalLibraries':
          return <String>[];
        case 'isLTSBuild':
          return false;
        case 'ffmpegSession':
          return {'sessionId': validSession ? nextId++ : null, 'createTime': 0};
        case 'abstractSessionGetState':
          return 3; // Completed; no event delivered.
        case 'abstractSessionGetReturnCode':
          return 0;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test('terminal state recovers a missing completion event', () async {
    final result = await FFmpegBackend().execute([
      '-version',
    ], onStatistics: (_) {});
    expect(result.exitCode, 0);
    expect(
      calls.any((call) => call.method == 'abstractSessionGetState'),
      isTrue,
    );
  });

  test('invalid session IDs never invoke cancel-all', () async {
    validSession = false;
    await expectLater(
      FFmpegBackend().execute(['-version'], onStatistics: (_) {}),
      throwsA(isA<AppFailure>()),
    );
    expect(calls.where((call) => call.method == 'cancel'), isEmpty);
  });
}
