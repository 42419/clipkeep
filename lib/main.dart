import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import 'routes/app_router.dart';
import 'stores/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 双保险：即使主题重建覆盖了 MaterialApp.builder 的 edge-to-edge 处理，
  // 也确保窗口是 edge-to-edge、系统栏透明。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  // 第三方来源单独一项，许可证页里保留中文致谢与许可说明。
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      <String>['第三方来源与致谢'],
      'Flutter / Dart（BSD-3-Clause）\n'
      'DTK 解析服务（Apache-2.0）—— 抖音解析服务，仅通过 REST 调用\n'
      'flutter_live_motion（MIT）—— Android Motion Photo 合成\n'
      '其余 pub.dev 依赖遵循各自许可证\n\n'
      '本应用与抖音无隶属关系，仅供学习研究；请仅下载你有权保存的内容。\n'
      '完整源码：https://github.com/42419/clipkeep',
    );
  });
  // 先读完设置再建主题，避免关闭动态取色的用户首帧闪一下动态色。
  final SettingsStore settings = SettingsStore();
  await settings.load();
  runApp(getRootWidget(settingsStore: settings));
}
