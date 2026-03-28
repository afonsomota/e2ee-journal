// theme.dart — "The Quiet Archivist" design system

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Orchard-inspired color palette
class AppColors {
  AppColors._();

  // Primary (deep green — trust, growth)
  static const primary = Color(0xFF1B6D24);
  static const primaryContainer = Color(0xFF5DAC5B);
  static const onPrimary = Color(0xFFFFFFFF);
  static const onPrimaryContainer = Color(0xFF003C0A);

  // Secondary (warm orange — emotional pulse)
  static const secondary = Color(0xFFB02E00);
  static const secondaryContainer = Color(0xFFFE5825);
  static const secondaryFixed = Color(0xFFFFDBD1);
  static const onSecondaryFixed = Color(0xFF3B0900);

  // Tertiary (warm gold — aged, archival)
  static const tertiary = Color(0xFF7E5700);

  // Error
  static const error = Color(0xFFBA1A1A);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF93000A);

  // Surface tonal palette (warm off-whites)
  static const background = Color(0xFFFAF9F6);
  static const surface = Color(0xFFFAF9F6);
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFF4F3F1);
  static const surfaceContainer = Color(0xFFEFEEEB);
  static const surfaceContainerHigh = Color(0xFFE9E8E5);
  static const surfaceContainerHighest = Color(0xFFE3E2E0);

  // On-surface (ink, not pure black)
  static const onSurface = Color(0xFF1A1C1A);
  static const onSurfaceVariant = Color(0xFF3F4A3C);
  static const outline = Color(0xFF6F7A6B);
  static const outlineVariant = Color(0xFFBECAB9);
}

/// Typography: Newsreader (serif, editorial) + Manrope (clean, modern)
class AppTypography {
  AppTypography._();

  // Serif headlines
  static TextStyle displayLarge = GoogleFonts.newsreader(
    fontSize: 40,
    fontWeight: FontWeight.w700,
    fontStyle: FontStyle.italic,
    color: AppColors.onSurface,
    height: 1.15,
  );

  static TextStyle headlineLarge = GoogleFonts.newsreader(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: AppColors.onSurface,
    height: 1.2,
  );

  static TextStyle headlineMedium = GoogleFonts.newsreader(
    fontSize: 26,
    fontWeight: FontWeight.w600,
    fontStyle: FontStyle.italic,
    color: AppColors.onSurface,
    height: 1.25,
  );

  static TextStyle headlineSmall = GoogleFonts.newsreader(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    fontStyle: FontStyle.italic,
    color: AppColors.onSurface,
    height: 1.3,
  );

  // Sans-serif body
  static TextStyle bodyLarge = GoogleFonts.manrope(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurface,
    height: 1.6,
  );

  static TextStyle bodyMedium = GoogleFonts.manrope(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurfaceVariant,
    height: 1.5,
  );

  static TextStyle bodySmall = GoogleFonts.manrope(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.outline,
    height: 1.4,
  );

  // Labels (uppercase, tracking)
  static TextStyle labelLarge = GoogleFonts.manrope(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.5,
    color: AppColors.outline,
  );

  static TextStyle labelSmall = GoogleFonts.manrope(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 2.0,
    color: AppColors.outline,
  );
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: const ColorScheme.light(
      primary: AppColors.primary,
      primaryContainer: AppColors.primaryContainer,
      onPrimary: AppColors.onPrimary,
      secondary: AppColors.secondary,
      secondaryContainer: AppColors.secondaryContainer,
      tertiary: AppColors.tertiary,
      error: AppColors.error,
      errorContainer: AppColors.errorContainer,
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
      onSurfaceVariant: AppColors.onSurfaceVariant,
      outline: AppColors.outline,
      outlineVariant: AppColors.outlineVariant,
    ),
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: GoogleFonts.newsreader(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: AppColors.primary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceContainerLowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      labelStyle: GoogleFonts.manrope(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: AppColors.outline,
      ),
      hintStyle: GoogleFonts.manrope(
        fontSize: 15,
        color: AppColors.outlineVariant,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.manrope(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: GoogleFonts.manrope(
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: AppColors.surface,
    ),
  );
}
