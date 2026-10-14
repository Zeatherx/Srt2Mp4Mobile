import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srt2mp4_mobile/main.dart';
import 'package:srt2mp4_mobile/ui/views/home_screen.dart';

void main() {
  testWidgets(
    'uses exact navy palette and translation is optional by default',
    (tester) async {
      await tester.pumpWidget(const SubtitleApp());
      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF060A12));
      expect(theme.colorScheme.surface, const Color(0xFF111827));
      expect(theme.colorScheme.primary, const Color(0xFF00C3FF));
      expect(theme.colorScheme.onSurface, Colors.white);
      expect(theme.colorScheme.onSurfaceVariant, const Color(0xFFA0AEC0));
      expect(find.text('Source Language'), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('Source Language'), findsOneWidget);
      expect(find.text('Target Language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Spanish'), findsOneWidget);
      await tester.ensureVisible(find.text('Spanish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spanish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Indonesian').last);
      await tester.pumpAndSettle();
      expect(find.text('Indonesian'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('language pickers fit narrow screens with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SubtitleApp.darkTheme,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 1000),
            textScaler: TextScaler.linear(1.4),
          ),
          child: const HomeScreen(),
        ),
      ),
    );
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Target Language'));
    await tester.pumpAndSettle();
    expect(find.text('Spanish'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
