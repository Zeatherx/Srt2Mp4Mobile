import 'dart:io';

class SelectedMedia {
  const SelectedMedia({
    required this.name,
    required this.file,
    required this.size,
    this.duration,
  });

  final String name;
  final File file;
  final int size;
  // For SRT this is the last cue end time, not a media stream duration.
  final Duration? duration;
}
