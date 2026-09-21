import 'package:flutter/material.dart';

/// App-wide dark theme (Android-first).
class AppTheme {
  static const bg = Color(0xFF0D1117);
  static const surface = Color(0xFF161B22);
  static const surface2 = Color(0xFF1C2330);
  static const border = Color(0xFF2D333B);
  static const text = Color(0xFFE6EDF3);
  static const muted = Color(0xFF8B949E);
  static const accent = Color(0xFF3B82F6);
  static const ok = Color(0xFF2EA043);
  static const warn = Color(0xFFD29922);
  static const err = Color(0xFFF85149);

  // Home screen visual identity (very dark navy + electric blue accents).
  static const navyBg = Color(0xFF05080F); // page background, near-black navy
  static const navyPanel = Color(0xFF0C1220); // menu / popup panel base
  static const glowAccent = Color(0xFF3B82F6); // neon-blue outline + glow
  static const glowSoft = Color(0x333B82F6); // soft outer glow (blue @ 20%)

  // Gold accent — reserved for the header's API-key control.
  static const gold = Color(0xFFF5C542);
  static const goldSoft = Color(0x2BF5C542); // gold glow @ ~17%

  /// Premium ambient background: near-black navy with a faint electric-blue
  /// glow rising from the top and a deeper haze near the composer.
  static const homeBackground = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF070C18), // top: navy with the faintest blue cast
      Color(0xFF05080F), // mid: near-black navy
      Color(0xFF060B16), // bottom: faint haze behind the composer
    ],
    stops: [0.0, 0.55, 1.0],
  );

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accent,
        surface: surface,
        error: err,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
      ),
      // Copy the platform's card-theme type so this remains compatible with
      // Flutter versions that use CardTheme and newer versions that use
      // CardThemeData for ThemeData.cardTheme.
      cardTheme: base.cardTheme.copyWith(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        hintStyle: const TextStyle(color: muted),
        labelStyle: const TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: border),
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      listTileTheme: const ListTileThemeData(iconColor: muted),
      dividerColor: border,
      // Modern dark toast instead of the stock white strip: floating,
      // rounded navy panel with readable text and accent actions.
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surface2,
        elevation: 8,
        contentTextStyle: TextStyle(color: text, fontSize: 13.5, height: 1.35),
        actionTextColor: glowAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: border),
        ),
        insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
