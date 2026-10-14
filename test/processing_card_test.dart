import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/main.dart';
import 'package:srt2mp4_mobile/models/encoding_progress.dart';
import 'package:srt2mp4_mobile/services/translation_service.dart';
import 'package:srt2mp4_mobile/ui/widgets/processing_card.dart';

void main() {
  testWidgets('progress bursts do not rebuild the surrounding screen', (
    tester,
  ) async {
    final encoding = ValueNotifier(const EncodingProgress());
    final translation = ValueNotifier(const TranslationProgress('Translating'));
    addTearDown(encoding.dispose);
    addTearDown(translation.dispose);
    var surroundingBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: SubtitleApp.darkTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              surroundingBuilds++;
              return ProcessingCard(
                encodingProgress: encoding,
                translationProgress: translation,
                translating: false,
                cancelling: false,
                onCancel: () {},
              );
            },
          ),
        ),
      ),
    );
    final before = surroundingBuilds;
    for (var i = 0; i < 1000; i++) {
      encoding.value = EncodingProgress(fraction: i / 1000);
    }
    await tester.pump();
    expect(find.text('Encoding 99%'), findsOneWidget);
    expect(surroundingBuilds, before);
  });
}
