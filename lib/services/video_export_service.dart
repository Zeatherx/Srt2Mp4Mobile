import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/exported_video.dart';

class VideoExportService {
  VideoExportService({bool? isAndroid})
    : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channel = MethodChannel('srt2mp4_mobile/video_export');
  final bool _isAndroid;
  bool _publicAvailable = true;

  /// Android 10+ public directories are created by MediaStore when publishing.
  /// Encode in cache first so incomplete videos never appear in the gallery.
  Future<File> createWorkingFile() async {
    Directory directory;
    if (_isAndroid) {
      _publicAvailable = true;
      try {
        final info = await _channel.invokeMapMethod<String, dynamic>(
          'getExportInfo',
        );
        if (info == null) throw StateError('Android storage is unavailable.');
        if ((info['sdkInt'] as int) <= 28) {
          final granted = await Permission.storage.request();
          if (!granted.isGranted) {
            throw const FileSystemException(
              'Storage permission is required to export videos on this Android version.',
            );
          }
          await Directory(info['directory'] as String).create(recursive: true);
        }
      } on PlatformException catch (error) {
        if (error.code != 'STORAGE_UNAVAILABLE') rethrow;
        _publicAvailable = false;
      } on FileSystemException {
        _publicAvailable = false;
      }
      final cache = await getTemporaryDirectory();
      directory = Directory(p.join(cache.path, 'srt2mp4_encoding'));
    } else {
      final documents = await getApplicationDocumentsDirectory();
      directory = Directory(
        p.join(documents.path, 'video', 'srt2mp4', 'export'),
      );
    }
    // Async recursive creation avoids blocking Flutter's UI thread.
    await directory.create(recursive: true);
    return File(
      p.join(
        directory.path,
        'subtitled_${DateTime.now().microsecondsSinceEpoch}.mp4',
      ),
    );
  }

  Future<ExportedVideo> publish(File workingFile) async {
    if (_isAndroid) {
      if (!_publicAvailable) return _savePrivateFallback(workingFile);
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'publishVideo',
          {
            'sourcePath': workingFile.path,
            'fileName': p.basename(workingFile.path),
          },
        );
        if (result == null) {
          throw StateError('Android did not return an export destination.');
        }
        return ExportedVideo(
          path: result['path'] as String,
          playbackUri: Uri.parse(result['uri'] as String),
          size: result['size'] as int,
          isPublic: true,
        );
      } on PlatformException catch (error) {
        if (error.code != 'EXPORT_FAILED' &&
            error.code != 'STORAGE_UNAVAILABLE') {
          rethrow;
        }
        return _savePrivateFallback(workingFile);
      }
    }
    return ExportedVideo(
      path: workingFile.path,
      playbackUri: workingFile.uri,
      size: await workingFile.length(),
    );
  }

  Future<void> cancelPublication() async {
    if (_isAndroid) await _channel.invokeMethod<void>('cancelExport');
  }

  Future<void> discard(ExportedVideo video) async {
    if (_isAndroid && video.isPublic) {
      await _channel.invokeMethod<void>('deleteExport', {
        'uri': video.playbackUri.toString(),
      });
    } else {
      final file = File.fromUri(video.playbackUri);
      if (await file.exists()) await file.delete();
    }
  }

  Future<ExportedVideo> _savePrivateFallback(File workingFile) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = await Directory(
      p.join(documents.path, 'video', 'srt2mp4', 'export'),
    ).create(recursive: true);
    final destination = File(
      p.join(directory.path, p.basename(workingFile.path)),
    );
    if (await destination.exists()) {
      throw const FileSystemException(
        'An export with this name already exists. Retry the export.',
      );
    }
    File saved;
    try {
      // App cache and documents normally share a volume; rename avoids another
      // full-video copy and extra disk usage when shared storage is unavailable.
      saved = await workingFile.rename(destination.path);
    } on FileSystemException {
      try {
        saved = await workingFile.copy(destination.path);
      } catch (_) {
        if (await destination.exists()) await destination.delete();
        rethrow;
      }
    }
    return ExportedVideo(
      path: saved.path,
      playbackUri: saved.uri,
      size: await saved.length(),
      storageNotice:
          'Public video storage was unavailable. Saved to the app documents folder instead.',
    );
  }

  Future<void> releaseWorkingFile(File file, {required bool succeeded}) async {
    if (!_isAndroid && succeeded) return; // This is the permanent iOS export.
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Preserve the original result/error. */
    }
  }
}
