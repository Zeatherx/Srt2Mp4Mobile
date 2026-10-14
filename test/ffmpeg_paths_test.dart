import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/services/ffmpeg_paths.dart';

void main() {
  test('escapes filter option delimiters through both parsing layers', () {
    expect(escapeSubtitleFilterPath('/a:b.srt'), r'/a\\:b.srt');
    expect(escapeSubtitleFilterPath("/a'b.srt"), r"/a\\\'b.srt");
    expect(escapeSubtitleFilterPath('/a,b[1];.srt'), r'/a\,b\[1\]\;.srt');
    expect(escapeSubtitleFilterPath(r'C:\a.srt'), r'C\\:\\\\a.srt');
    expect(escapeSubtitleFilterPath('/a b.srt'), r'/a\\\ b.srt');
    expect(escapeSubtitleFilterPath('/字幕.srt'), '/字幕.srt');
  });

  test('rejects empty paths and control characters', () {
    for (final path in ['', 'x\n.srt', 'x\r.srt', 'x\u0000.srt']) {
      expect(() => escapeSubtitleFilterPath(path), throwsArgumentError);
    }
  });

  test('passes input/output as single argv entries without shell quotes', () {
    final arguments = burnArguments(
      videoPath: '/my "video".mp4',
      subtitlePath: "/my:sub's.srt",
      fontDirectory: '/fonts',
      outputPath: '/output file.mp4',
    );
    expect(arguments[arguments.indexOf('-i') + 1], '/my "video".mp4');
    expect(arguments.last, '/output file.mp4');
    expect(
      arguments[arguments.indexOf('-vf') + 1],
      '${subtitleFilter("/my:sub's.srt", '/fonts')},pad=ceil(iw/2)*2:ceil(ih/2)*2',
    );
    expect(arguments, containsAll(['libx264', 'ultrafast', '23', 'copy']));
  });

  test('preserves CJK and astral Unicode while escaping delimiters', () {
    const path = '/\u5b57\u5e55\u{1F3AC}.srt';
    expect(escapeSubtitleFilterPath(path), path);
  });
}
