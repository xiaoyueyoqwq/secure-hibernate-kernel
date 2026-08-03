import 'package:flutter/material.dart';

abstract final class Neutral {
  static const n50 = Color(0xfffafafa);
  static const n100 = Color(0xfff5f5f5);
  static const n200 = Color(0xffe5e5e5);
  static const n300 = Color(0xffd4d4d4);
  static const n400 = Color(0xffa3a3a3);
  static const n500 = Color(0xff737373);
  static const n600 = Color(0xff525252);
  static const n700 = Color(0xff404040);
  static const n800 = Color(0xff262626);
  static const n900 = Color(0xff171717);
  static const n950 = Color(0xff0a0a0a);
}

class AppPalette {
  const AppPalette(this.dark);

  final bool dark;

  Color get outerBackground => dark ? Neutral.n900 : Neutral.n100;
  Color get contentBackground => dark ? Neutral.n950 : Neutral.n50;
  Color get card => dark ? Colors.black : Colors.white;
  Color get border => (dark ? Neutral.n800 : Neutral.n200).withValues(
        alpha: dark ? 0.70 : 0.60,
      );
  Color get strongBorder => (dark ? Neutral.n700 : Neutral.n200).withValues(
        alpha: dark ? 0.80 : 0.80,
      );
  Color get text => dark ? Colors.white : Neutral.n900;
  Color get textStrong => dark ? Neutral.n100 : Neutral.n900;
  Color get textMedium => dark ? Neutral.n300 : Neutral.n700;
  Color get textMuted => dark ? Neutral.n400 : Neutral.n500;
  Color get textFaint => Neutral.n500;
  Color get activeFill => dark ? Neutral.n100 : Neutral.n950;
  Color get activeText => dark ? Neutral.n950 : Colors.white;
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      AppPalette(Theme.of(this).brightness == Brightness.dark);
}

ThemeData buildManagerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = AppPalette(dark);
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    fontFamily: 'Ubuntu',
    scaffoldBackgroundColor: palette.outerBackground,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    colorScheme: dark
        ? const ColorScheme.dark(
            surface: Neutral.n950,
            primary: Colors.white,
            onPrimary: Colors.black,
            error: Color(0xffdc2626),
          )
        : const ColorScheme.light(
            surface: Neutral.n50,
            primary: Colors.black,
            onPrimary: Colors.white,
            error: Color(0xffdc2626),
          ),
  );
  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          fontFamily: 'Ubuntu',
          bodyColor: palette.text,
          displayColor: palette.text,
        )
        .copyWith(
          headlineSmall: TextStyle(
            color: palette.text,
            fontSize: 20,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          titleMedium: TextStyle(
            color: palette.text,
            fontSize: 18,
            height: 1.35,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
          titleSmall: TextStyle(
            color: palette.textMedium,
            fontSize: 14,
            height: 1.4,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          bodyMedium: TextStyle(
            color: palette.textMedium,
            fontSize: 14,
            height: 1.5,
            fontWeight: FontWeight.w400,
            letterSpacing: 0,
          ),
          bodySmall: TextStyle(
            color: palette.textMuted,
            fontSize: 12,
            height: 1.55,
            fontWeight: FontWeight.w400,
            letterSpacing: 0,
          ),
          labelMedium: TextStyle(
            color: palette.textMedium,
            fontSize: 12,
            height: 1.3,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? Neutral.n100 : Neutral.n900,
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: TextStyle(
        color: dark ? Neutral.n950 : Colors.white,
        fontFamily: 'Ubuntu',
        fontSize: 11,
        letterSpacing: 0,
      ),
      waitDuration: const Duration(milliseconds: 450),
    ),
  );
}
