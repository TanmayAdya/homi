import 'package:flutter/material.dart';

abstract final class SafeAtHomeTheme {
  static const ivory = Color(0xFFF8F5EE);
  static const teal = Color(0xFF174E49);
  static const ink = Color(0xFF233E3A);
  static const mutedInk = Color(0xFF51655F);
  static const coral = Color(0xFF9E4839);
  static const line = Color(0xFFD9DFD6);

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: teal,
          brightness: Brightness.light,
        ).copyWith(
          primary: teal,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFDCEBE3),
          onPrimaryContainer: teal,
          secondary: const Color(0xFF526653),
          secondaryContainer: const Color(0xFFE8EBDC),
          onSecondaryContainer: ink,
          tertiary: coral,
          tertiaryContainer: const Color(0xFFF7E4DC),
          onTertiaryContainer: const Color(0xFF743326),
          surface: const Color(0xFFFFFEFA),
          onSurface: ink,
          onSurfaceVariant: mutedInk,
          surfaceContainerLowest: const Color(0xFFFFFEFA),
          surfaceContainerLow: const Color(0xFFF2F0E8),
          surfaceContainer: const Color(0xFFECEEE5),
          outline: const Color(0xFF77877E),
          outlineVariant: line,
          error: const Color(0xFF9B3028),
          onError: Colors.white,
          errorContainer: const Color(0xFFF9E3DF),
          onErrorContainer: const Color(0xFF74231D),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ivory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    return base.copyWith(
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          height: 1.18,
          letterSpacing: -.6,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          height: 1.2,
          letterSpacing: -.4,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 17, height: 1.45),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 16, height: 1.45),
        bodySmall: text.bodySmall?.copyWith(fontSize: 14, height: 1.45),
        labelLarge: text.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ivory,
        foregroundColor: teal,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium?.copyWith(
          color: teal,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: line),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        helperMaxLines: 5,
        errorMaxLines: 5,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: teal, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      dividerTheme: const DividerThemeData(color: line, space: 32),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 16,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: teal),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
