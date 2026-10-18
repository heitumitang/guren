/// 微信绿主题：主色对齐微信绿（#07C160），危险/删除/未读红点保留朱砂红。
/// 全 App 字体为 Noto Serif SC（宋体衬线，见 pubspec.yaml fonts）。
import 'package:flutter/material.dart';

const Color kPaper = Color(0xFFF7F3EC);
const Color kPaperDark = Color(0xFF1B1916);
const Color kInk = Color(0xFF2B2622);
const Color kInkDark = Color(0xFFEDE6DA);
const Color kWechatGreen = Color(0xFF07C160);      // 微信绿（主色）
const Color kWechatGreenSoft = Color(0xFF95EC69);  // 微信气泡绿（发出的消息）
const Color kCinnabar = Color(0xFFB23A2E);          // 朱砂红（危险/删除/未读红点）
const Color kLine = Color(0x331C1A17);
const Color kLineDark = Color(0x33F2E9DC);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final surface = dark ? kPaperDark : kPaper;
  final onSurface = dark ? kInkDark : kInk;
  final line = dark ? kLineDark : kLine;

  // fromSeed 生成完整 ColorScheme（避免新版 Flutter 构造器缺参报错），再覆盖关键色。
  final scheme = ColorScheme.fromSeed(
    seedColor: kWechatGreen,
    brightness: b,
  ).copyWith(
    primary: kWechatGreen,
    onPrimary: Colors.white,
    secondary: kWechatGreenSoft,
    surface: surface,
    onSurface: onSurface,
    background: surface,
    onBackground: onSurface,
    error: kCinnabar,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: surface,
    colorScheme: scheme,
    dividerColor: line,
    fontFamily: 'NotoSerifSC',
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: onSurface),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSerifSC',
        color: onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kWechatGreen,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kWechatGreen),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kWechatGreen),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
    ),
  );
}

