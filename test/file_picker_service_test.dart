import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:srt2mp4_mobile/services/file_picker_service.dart';

class _Picker extends FilePicker {
  _Picker(this.file);
  final PlatformFile file;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([file]);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Directory imports;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('import_audit_');
    imports = await Directory(p.join(directory.path, 'cache')).create();
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(imports);
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  test('copy failures remove the reserved import directory', () async {
    FilePicker.platform = _Picker(
      PlatformFile(
        name: 'missing.srt',
        size: 10,
        path: p.join(directory.path, 'missing.srt'),
      ),
    );
    await expectLater(
      FilePickerService().pickSubtitles(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await imports.list().length, 0);
  });

  test(
    'malformed SRT is rejected during import with translation disabled',
    () async {
      final source = await File(
        p.join(directory.path, 'invalid.srt'),
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nGood\n\nBROKEN BLOCK');
      FilePicker.platform = _Picker(
        PlatformFile(
          name: 'invalid.srt',
          size: await source.length(),
          path: source.path,
        ),
      );
      await expectLater(
        FilePickerService().pickSubtitles(),
        throwsFormatException,
      );
      expect(await imports.list().length, 0);
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'release removes only owned copies and retains the original file',
    () async {
      final source = await File(
        p.join(directory.path, 'valid.srt'),
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nGood');
      FilePicker.platform = _Picker(
        PlatformFile(
          name: 'valid.srt',
          size: await source.length(),
          path: source.path,
        ),
      );
      final service = FilePickerService();
      final selected = (await service.pickSubtitles())!;
      expect(selected.duration, const Duration(seconds: 2));
      await service.release(selected.file);
      await service.release(selected.file);
      await service.release(source);
      expect(await source.exists(), isTrue);
      expect(await imports.list().length, 0);
    },
  );
}
