import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/models/srt_document.dart';

void main() {
  test('rejects reversed cue times and reports the actual last cue end', () {
    expect(
      () => SrtDocument.parse('1\n00:00:04,000 --> 00:00:03,000\nBackwards'),
      throwsFormatException,
    );
    final document = SrtDocument.parse(
      '1\n00:00:00,000 --> 00:00:03,000\nHello',
    );
    expect(document.duration, const Duration(seconds: 3));
  });
  const input =
      '\uFEFF001\r\n00:00:01,200 --> 00:00:03,400  X1:1 X2:2\r\n'
      '<i>Hello!</i>\r\nSecond line.\r\n \r\n'
      ' 009 \n00:00:05.000 --> 00:00:07.000\nGoodbye.';

  test('parses indexes, exact timecodes and multiline cues', () {
    final document = SrtDocument.parse(input);
    expect(document.blocks.length, 2);
    expect(document.blocks.first.index, '\uFEFF001');
    expect(
      document.blocks.first.timecode,
      '00:00:01,200 --> 00:00:03,400  X1:1 X2:2',
    );
    expect(document.blocks.first.textLines, ['<i>Hello!</i>', 'Second line.']);
    expect(document.blocks.last.index, ' 009 ');
    expect(document.build({}), input);
  });

  test(
    'replaces only cue text, retaining BOM, mixed endings and separators',
    () {
      final document = SrtDocument.parse(input);
      final output = document.build({
        2: '<i>¡Hola!</i>',
        3: 'Segunda línea.',
        7: 'Adiós.',
      });
      expect(
        output,
        input
            .replaceFirst('<i>Hello!</i>', '<i>¡Hola!</i>')
            .replaceFirst('Second line.', 'Segunda línea.')
            .replaceFirst('Goodbye.', 'Adiós.'),
      );
      final parsed = SrtDocument.parse(output);
      expect(
        parsed.blocks.map((cue) => cue.index),
        document.blocks.map((cue) => cue.index),
      );
      expect(
        parsed.blocks.map((cue) => cue.timecode),
        document.blocks.map((cue) => cue.timecode),
      );
    },
  );

  test('rejects writes to metadata or invalid translated lines', () {
    final document = SrtDocument.parse(input);
    for (final replacement in [
      {0: '2'},
      {1: 'new timing'},
      {4: 'separator'},
      {2: ''},
      {2: 'one\n\ntwo'},
      {2: 'x\u0000'},
    ]) {
      expect(() => document.build(replacement), throwsFormatException);
    }
  });

  test('rejects malformed files instead of translating timestamps as text', () {
    for (final text in [
      '',
      'Not an SRT',
      '1\n00:99:00,000 --> 00:00:01,000\nText',
      '1\n00:00:00,000 --> 00:00:01,000\n',
      '1\n00:00:00,000 --> 00:00:01,000\nHello\n2\n00:00:02,000 --> 00:00:03,000\nBye',
    ]) {
      expect(() => SrtDocument.parse(text), throwsFormatException);
    }
  });
}
