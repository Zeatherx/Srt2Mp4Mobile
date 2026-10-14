import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:srt2mp4_mobile/services/video_export_service.dart';

class _ExportPaths extends PathProviderPlatform {
  _ExportPaths(this.directory);
  final Directory directory;
  @override
  Future<String?> getTemporaryPath() async => p.join(directory.path, 'cache');
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(directory.path, 'documents');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('srt2mp4_mobile/video_export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late PathProviderPlatform oldPaths;
  late List<MethodCall> calls;
  late bool failPublication;
  const publicPath =
      '/storage/emulated/0/Movies/srt2mp4/export/subtitled_123.mp4';
  const publicUri = 'content://media/external_primary/video/media/123';

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('video_export_test_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ExportPaths(temporary);
    calls = [];
    failPublication = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getExportInfo':
          return {
            'sdkInt': 36,
            'directory': '/storage/emulated/0/Movies/srt2mp4/export',
          };
        case 'publishVideo':
          if (failPublication) {
            throw PlatformException(
              code: 'EXPORT_FAILED',
              message: 'Storage full',
            );
          }
          return {'path': publicPath, 'uri': publicUri, 'size': 4};
        case 'cancelExport':
        case 'deleteExport':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = oldPaths;
    await temporary.delete(recursive: true);
  });

  test(
    'Android stages encoding then returns public Movies path and playback URI',
    () async {
      final service = VideoExportService(isAndroid: true);
      final file = await service.createWorkingFile();
      expect(
        file.parent.path,
        p.join(temporary.path, 'cache', 'srt2mp4_encoding'),
      );
      expect(await file.parent.exists(), isTrue);
      await file.writeAsBytes([1, 2, 3, 4]);
      final result = await service.publish(file);
      expect(result.path, publicPath);
      expect(result.playbackUri.toString(), publicUri);
      expect(result.size, 4);
      expect(calls.last.arguments, {
        'sourcePath': file.path,
        'fileName': p.basename(file.path),
      });
      await service.releaseWorkingFile(file, succeeded: true);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'iOS creates video/srt2mp4/export recursively and retains finished files',
    () async {
      final service = VideoExportService(isAndroid: false);
      final file = await service.createWorkingFile();
      expect(
        file.parent.path,
        p.join(temporary.path, 'documents', 'video', 'srt2mp4', 'export'),
      );
      expect(await file.parent.exists(), isTrue);
      await file.writeAsBytes([1, 2]);
      final result = await service.publish(file);
      expect(result.path, file.path);
      expect(result.playbackUri, file.uri);
      expect(result.size, 2);
      await service.releaseWorkingFile(file, succeeded: true);
      expect(await file.exists(), isTrue);
      expect(calls, isEmpty);
    },
  );

  test(
    'failed public publication falls back to documents and reports its location',
    () async {
      final service = VideoExportService(isAndroid: true);
      final file = await service.createWorkingFile();
      await file.writeAsBytes([1]);
      failPublication = true;
      final result = await service.publish(file);
      expect(result.isPublic, isFalse);
      expect(result.storageNotice, contains('app documents'));
      expect(
        result.path,
        contains(p.join('documents', 'video', 'srt2mp4', 'export')),
      );
      expect(await File(result.path).exists(), isTrue);
      await service.releaseWorkingFile(file, succeeded: true);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'cancellation can stop publication and remove a just-published video',
    () async {
      final service = VideoExportService(isAndroid: true);
      final file = await service.createWorkingFile();
      await file.writeAsBytes([1]);
      final result = await service.publish(file);
      await service.cancelPublication();
      await service.discard(result);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder(['publishVideo', 'cancelExport', 'deleteExport']),
      );
      expect(calls.last.arguments, {'uri': publicUri});
      await service.releaseWorkingFile(file, succeeded: false);
    },
  );
}
