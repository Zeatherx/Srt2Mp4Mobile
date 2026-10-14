import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/main.dart';
import 'package:srt2mp4_mobile/models/app_failure.dart';
import 'package:srt2mp4_mobile/models/selected_media.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_service.dart';
import 'package:srt2mp4_mobile/services/file_picker_service.dart';
import 'package:srt2mp4_mobile/ui/views/home_screen.dart';

class _Picker extends FilePickerService {
  final selected = Completer<SelectedMedia?>();
  final released = <File>[];
  @override
  Future<SelectedMedia?> pickVideo() => selected.future;
  @override
  Future<void> release(File? file) async {
    if (file != null) released.add(file);
  }
}

class _Encoder extends FFmpegService {
  int disposed = 0;
  @override
  Future<void> cancel() async =>
      throw const AppFailure('Injected cancellation bridge error');
  @override
  Future<void> dispose() async {
    disposed++;
    await super.dispose();
  }
}

void main() {
  testWidgets(
    'unmount while picking handles cancellation errors and releases the late result',
    (tester) async {
      final picker = _Picker();
      final encoder = _Encoder();
      await tester.pumpWidget(
        MaterialApp(
          theme: SubtitleApp.darkTheme,
          home: HomeScreen(filePicker: picker, encoder: encoder),
        ),
      );
      await tester.tap(find.text('Select video'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      final file = File('/not-a-real-native-file.mp4');
      picker.selected.complete(
        SelectedMedia(
          name: 'video.mp4',
          file: file,
          size: 10,
          duration: const Duration(seconds: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(picker.released, contains(file));
      expect(encoder.disposed, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
