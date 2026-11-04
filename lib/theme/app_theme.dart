import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

/// 应用主题：颜色种子、圆角/间距等设计令牌集中在这里。
class AppTheme {
  AppTheme._();

  /// 设计稿主色（绿色）。dynamicColoring 可用时会被壁纸取色覆盖，作为回退。
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

  static M3EThemeData light() => M3EThemeData.light(seedColor: seed);

  static M3EThemeData dark() => M3EThemeData.dark(seedColor: seed);
}
