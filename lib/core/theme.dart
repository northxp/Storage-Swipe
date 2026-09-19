// lib/core/theme.dart
//
// CORE LAYER
// ----------
// The `core/` folder holds app-wide concerns that don't belong to any one
// feature: theming, permission plumbing, constants, routing helpers, etc.
// Nothing in `core/` should know about `CustomAsset`, Riverpod providers,
// or any specific screen — it is the foundation everything else sits on.

import 'package:flutter/material.dart';

/// Centralised color + typography tokens for the app.
///
/// Keeping these as static constants (rather than scattering hex codes
/// through the widget tree) means the "gamified" visual identity — the
/// keep/delete color language — is defined exactly once.
class AppColors {
  AppColors._();

  // The swipe-right ("Keep") color. Calm, reassuring green.
  static const Color keep = Color(0xFF2ECC71);

  // The swipe-left ("Delete") color. Urgent but not alarming red.
  static const Color delete = Color(0xFFE74C3C);

  // Primary brand color used for buttons, progress bars, highlights.
  static const Color primary = Color(0xFF6C5CE7);

  static const Color background = Color(0xFF0F0F1A);
  static const Color surface = Color(0xFF1B1B2F);
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFFA0A0B2);
}

/// Builds the single [ThemeData] instance used by [MaterialApp].
///
/// Isolating this in `core/theme.dart` means designers/contributors can
/// re-skin the whole app without touching a single screen file.
ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: AppColors.textPrimary,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w700,
      ),
      bodyMedium: TextStyle(color: AppColors.textSecondary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
  );
}
