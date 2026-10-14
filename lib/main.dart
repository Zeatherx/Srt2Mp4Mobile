import 'package:flutter/material.dart';

import 'ui/views/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SubtitleApp());
}

class SubtitleApp extends StatelessWidget {
  const SubtitleApp({super.key});

  static ThemeData get darkTheme {
    const background = Color(0xFF060A12);
    const surface = Color(0xFF111827);
    const accent = Color(0xFF00C3FF);
    const foreground = Color(0xFFFFFFFF);
    const muted = Color(0xFFA0AEC0);
    final border = muted.withValues(alpha: 0.24);
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.dark(
        primary: accent,
        onPrimary: background,
        secondary: accent,
        onSecondary: background,
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: muted,
        surfaceContainer: surface,
        surfaceContainerLow: surface,
        surfaceContainerHigh: surface,
        surfaceContainerHighest: surface,
        outline: border,
        outlineVariant: border,
        error: const Color(0xFFFF8793),
        onError: background,
      ),
      textTheme: base.textTheme
          .apply(bodyColor: foreground, displayColor: foreground)
          .copyWith(
            bodySmall: base.textTheme.bodySmall?.copyWith(color: muted),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        labelStyle: const TextStyle(color: muted),
        floatingLabelStyle: const TextStyle(color: accent),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        textStyle: TextStyle(color: foreground),
        menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(surface)),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: foreground,
        iconColor: accent,
        subtitleTextStyle: TextStyle(color: muted),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: background,
          disabledBackgroundColor: surface,
          disabledForegroundColor: muted,
          minimumSize: const Size(0, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: const BorderSide(color: accent),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : surface,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? background : muted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : muted,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: surface,
      ),
      iconTheme: const IconThemeData(color: muted),
      dividerTheme: DividerThemeData(color: border),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: foreground),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Srt2Mp4 Mobile',
    debugShowCheckedModeBanner: false,
    theme: darkTheme,
    darkTheme: darkTheme,
    themeMode: ThemeMode.dark,
    home: const HomeScreen(),
  );
}
