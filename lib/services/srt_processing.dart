import 'dart:convert';
import 'dart:io';

import '../models/srt_document.dart';

// A malformed or gigantic subtitle file should fail before it exhausts memory.
const maxSrtBytes = 16 * 1024 * 1024;

/// Called through compute(): file decoding and regex parsing stay off the UI.
Future<SrtDocument> loadSrtDocument(String path) async {
  final file = File(path);
  if (await file.length() > maxSrtBytes) {
    throw const FormatException('The subtitle file exceeds the 16 MB limit.');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > maxSrtBytes) {
    throw const FormatException('The subtitle file exceeds the 16 MB limit.');
  }
  var content = utf8.decode(bytes);
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    content = '\uFEFF$content';
  }
  return SrtDocument.parse(content);
}

Future<void> writeTranslatedSrt(
  (SrtDocument, Map<int, String>, String) request,
) async {
  final (document, translatedLines, path) = request;
  await File(path).writeAsString(document.build(translatedLines), flush: true);
}

Future<Duration> readSrtDuration(String path) async =>
    (await loadSrtDocument(path)).duration;
