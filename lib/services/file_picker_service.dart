import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/selected_media.dart';
import 'srt_processing.dart';

class FilePickerService {
  final _imports = <String, Directory>{};
  Future<SelectedMedia?> pickVideo() => _pick('mp4');
  Future<SelectedMedia?> pickSubtitles() => _pick('srt');

  Future<SelectedMedia?> _pick(String extension) async {
    // Native document pickers grant access to the chosen file. Broad media
    // permissions are unnecessary, including on Android 13+ and iOS.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
      allowMultiple: false,
      withData: false,
    );
    if (result == null) return null;
    final selected = result.files.single;
    if (p.extension(selected.name).toLowerCase() != '.$extension') {
      throw FormatException('Please select a .$extension file.');
    }
    if (selected.path == null) {
      throw const FileSystemException(
        'The provider did not return a local file.',
      );
    }
    // Own the copy so cloud/provider and picker cache lifetimes cannot break
    // an encoding. Streamed File.copy avoids loading a whole MP4 into Dart RAM.
    final temporary = await getTemporaryDirectory();
    final directory = await temporary.createTemp('subtitle_import_');
    final file = File(p.join(directory.path, 'input.$extension'));
    _imports[file.path] = directory;
    try {
      await File(selected.path!).copy(file.path);
      final size = await file.length();
      if (size == 0) throw const FormatException('The selected file is empty.');
      Duration? duration;
      if (extension == 'mp4') {
        final session = await FFprobeKit.getMediaInformation(file.path);
        final info = session.getMediaInformation();
        final seconds = double.tryParse(info?.getDuration() ?? '');
        final hasVideo =
            info?.getStreams().any((stream) => stream.getType() == 'video') ??
            false;
        if (!hasVideo || seconds == null || !seconds.isFinite || seconds <= 0) {
          throw const FormatException('Could not read the MP4 video duration.');
        }
        duration = Duration(milliseconds: (seconds * 1000).round());
      } else {
        duration = await compute(readSrtDuration, file.path);
      }
      return SelectedMedia(
        name: selected.name,
        file: file,
        size: size,
        duration: duration,
      );
    } catch (_) {
      await release(file);
      rethrow;
    }
  }

  Future<void> release(File? file) async {
    if (file == null) return;
    final directory = _imports[file.path];
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      _imports.remove(file.path);
    } on FileSystemException {
      /* Cache cleanup can be retried by the OS. */
    }
  }
}
