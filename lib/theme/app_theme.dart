import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// 应用主题：颜色种子、圆角/间距等设计令牌集中在这里。
class AppTheme {
  AppTheme._();

  /// 设计稿主色（绿色）。动态取色可用时会被壁纸取色覆盖，作为回退。
  static const Color seed = Color(0xFF2F6B3E);

  // 间距
  static const double gap = 16;
  static const double pagePadding = 16;

  // 圆角
  static const double radiusXl = 40;
  static const double radiusLg = 32;
  static const double radiusMd = 28;
  static const double radiusSm = 20;
  static const double radiusXs = 12;

  /// 亮色主题；[seedColor] 非空时用动态取色结果作种子。
  static ThemeData light({Color? seedColor}) =>
      _build(Brightness.light, seedColor);

  /// 暗色主题；[seedColor] 非空时用动态取色结果作种子。
  static ThemeData dark({Color? seedColor}) =>
      _build(Brightness.dark, seedColor);

  static ThemeData _build(Brightness brightness, Color? seedColor) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor ?? seed,
        brightness: brightness,
      ),
    );
  }

  /// 透明系统栏 + 按明暗切换图标颜色。
  ///
  /// edge-to-edge 下由 MaterialApp.builder 的 AnnotatedRegion 应用，
  /// 页面切换时会跟着主题亮度更新。
  static SystemUiOverlayStyle overlayStyle(Brightness brightness) {
    final Brightness iconBrightness = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: iconBrightness,
      systemNavigationBarIconBrightness: iconBrightness,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );
  }
}
