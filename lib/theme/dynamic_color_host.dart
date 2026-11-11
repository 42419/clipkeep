import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// 把设备动态取色（Material You）解析成一组明暗 [ColorScheme]。
///
/// 优先读系统核心调色板，取其 primary 作为种子重新生成方案；
/// 不支持时回退强调色；两者都没有时交给调用方使用默认种子色。
class DynamicColorHost extends StatefulWidget {
  const DynamicColorHost({
    required this.enabled,
    required this.builder,
    super.key,
  });

  /// 是否启用动态取色（对应设置页开关）。
  final bool enabled;

  /// 用解析结果构建子树；未启用或设备不支持时两个参数均为 null。
  final Widget Function(ColorScheme? light, ColorScheme? dark) builder;

  @override
  State<DynamicColorHost> createState() => _DynamicColorHostState();
}

class _DynamicColorHostState extends State<DynamicColorHost>
    with WidgetsBindingObserver {
  ColorScheme? _light;
  ColorScheme? _dark;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enabled) {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(DynamicColorHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 换壁纸/换主题后回到前台，重新取色。
    if (state == AppLifecycleState.resumed && widget.enabled) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int seq = ++_seq;
    final Color? seed = await _readSeed();
    if (!mounted || seq != _seq || !widget.enabled || seed == null) {
      return;
    }
    setState(() {
      _light = ColorScheme.fromSeed(seedColor: seed);
      _dark = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      );
    });
  }

  Future<Color?> _readSeed() async {
    try {
      // CorePalette 由 material_color_utilities 定义、dynamic_color 未导出，
      // 这里用类型推断避免直接依赖其内部实现。
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        return palette.toColorScheme().primary;
      }
    } on PlatformException {
      // 设备不提供核心调色板，继续尝试强调色。
    }
    try {
      return await DynamicColorPlugin.getAccentColor();
    } on PlatformException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(_light, _dark);
}
