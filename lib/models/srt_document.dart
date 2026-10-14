/// A line retains its original ending, including mixed CRLF/LF input.
class SrtLine {
  const SrtLine(this.text, this.ending);
  final String text;
  final String ending;
}

class SrtBlock {
  const SrtBlock({
    required this.index,
    required this.timecode,
    required this.textLines,
    required this.firstTextLine,
  });
  // Keep these as strings: leading zeroes and whitespace are significant.
  final String index;
  final String timecode;
  final List<String> textLines;
  final int firstTextLine;
}

class SrtDocument {
  SrtDocument._(this.lines, this.blocks, this.duration);
  final List<SrtLine> lines;
  final List<SrtBlock> blocks;
  final Duration duration;

  static final _index = RegExp(r'^\s*\d+\s*$');
  static final _timecode = RegExp(
    r'^\s*(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})[ \t]+-->[ \t]+(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})(?:[ \t]+[^\r\n]*)?$',
  );

  factory SrtDocument.parse(String content) {
    final lines = <SrtLine>[];
    for (final match in RegExp(
      r'([^\r\n]*)(\r\n|\r|\n|$)',
    ).allMatches(content)) {
      if (match.start == content.length) break;
      lines.add(SrtLine(match[1]!, match[2]!));
    }
    final blocks = <SrtBlock>[];
    var lastEnd = Duration.zero;
    var cursor = 0;
    while (cursor < lines.length) {
      if (lines[cursor].text.trim().isEmpty) {
        cursor++;
        continue;
      }
      final index = lines[cursor].text;
      final plainIndex = cursor == 0 ? index.replaceFirst('\uFEFF', '') : index;
      if (!_index.hasMatch(plainIndex) ||
          cursor + 1 >= lines.length ||
          !_timecode.hasMatch(lines[cursor + 1].text)) {
        throw FormatException('Invalid SRT cue at line ${cursor + 1}.');
      }
      final timecode = lines[cursor + 1].text;
      final timing = _timecode.firstMatch(timecode)!;
      Duration timestamp(int offset) => Duration(
        hours: int.parse(timing[1 + offset]!),
        minutes: int.parse(timing[2 + offset]!),
        seconds: int.parse(timing[3 + offset]!),
        milliseconds: int.parse(timing[4 + offset]!),
      );
      final startTime = timestamp(0);
      final endTime = timestamp(4);
      if (endTime < startTime) {
        throw FormatException('SRT cue $plainIndex ends before it starts.');
      }
      if (endTime > lastEnd) lastEnd = endTime;
      cursor += 2;
      final start = cursor;
      while (cursor < lines.length && lines[cursor].text.trim().isNotEmpty) {
        if (_timecode.hasMatch(lines[cursor].text)) {
          throw FormatException(
            'Missing blank separator before line ${cursor + 1}.',
          );
        }
        cursor++;
      }
      if (start == cursor) {
        throw FormatException('SRT cue $plainIndex has no text.');
      }
      blocks.add(
        SrtBlock(
          index: index,
          timecode: timecode,
          textLines: List.unmodifiable(
            lines.sublist(start, cursor).map((line) => line.text),
          ),
          firstTextLine: start,
        ),
      );
    }
    if (blocks.isEmpty) {
      throw const FormatException('The SRT file contains no cues.');
    }
    return SrtDocument._(
      List.unmodifiable(lines),
      List.unmodifiable(blocks),
      lastEnd,
    );
  }

  /// Only text offsets can change. Headers, separator lines and line endings
  /// are reconstructed from the original data without normalization.
  String build(Map<int, String> translatedLines) {
    final allowed = <int>{
      for (final block in blocks)
        for (var i = 0; i < block.textLines.length; i++)
          block.firstTextLine + i,
    };
    for (final entry in translatedLines.entries) {
      if (!allowed.contains(entry.key) ||
          entry.value.contains(RegExp(r'[\r\n\x00]')) ||
          entry.value.trim().isEmpty) {
        throw const FormatException(
          'Translation would damage the SRT structure.',
        );
      }
    }
    final result = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      result.write(translatedLines[i] ?? lines[i].text);
      result.write(lines[i].ending);
    }
    return result.toString();
  }
}
