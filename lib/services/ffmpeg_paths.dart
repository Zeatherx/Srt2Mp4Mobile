/// Escape a token for libavutil's parser without shell quoting.
String _escape(String value, String special) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    if (special.contains(character)) result.write(r'\');
    result.write(character);
  }
  return result.toString();
}

/// Two parsers consume a -vf argument: the filtergraph parser, then the
/// subtitles option parser. Escape inside-out. executeWithArgumentsAsync
/// avoids a third (command/shell) parser; don't put quotes around these paths.
String escapeSubtitleFilterPath(String path) {
  if (path.isEmpty ||
      path.contains('\u0000') ||
      path.contains('\n') ||
      path.contains('\r')) {
    throw ArgumentError.value(path, 'path', 'Invalid local file path');
  }
  final option = _escape(path, "\\': \t");
  return _escape(option, "\\'[],; \t");
}

String subtitleFilter(String subtitlePath, String fontDirectory) =>
    'subtitles=filename=${escapeSubtitleFilterPath(subtitlePath)}'
    ':fontsdir=${escapeSubtitleFilterPath(fontDirectory)}'
    ':charenc=UTF-8'
    ':force_style=${escapeSubtitleFilterPath('Fontname=Noto Sans')}';

List<String> burnArguments({
  required String videoPath,
  required String subtitlePath,
  required String fontDirectory,
  required String outputPath,
}) => [
  '-hide_banner',
  '-loglevel',
  'warning',
  '-nostdin',
  '-y',
  '-i',
  videoPath,
  '-map',
  '0:v:0',
  '-map',
  '0:a?',
  '-vf',
  '${subtitleFilter(subtitlePath, fontDirectory)},pad=ceil(iw/2)*2:ceil(ih/2)*2',
  '-c:v',
  'libx264',
  '-preset',
  'ultrafast',
  '-crf',
  '23',
  '-pix_fmt',
  'yuv420p',
  '-c:a',
  'copy',
  '-movflags',
  '+faststart',
  outputPath,
];
