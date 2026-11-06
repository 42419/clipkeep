import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import 'routes/app_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 双保险：即使 M3EMaterialApp 的 drawUnderSystemBars 被主题重建覆盖，
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
  // 把 GPL 全文注册进 Flutter 的许可证页，APK 内可随时查看。
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString(
      'assets/licenses/GPL-3.0.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>['ClipKeep'], text);
  });
  // 第三方来源单独一项，许可证页里保留中文致谢与许可说明。
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      <String>['第三方来源与致谢'],
      'Flutter / Dart（BSD-3-Clause）\n'
      'FFmpegKit for Flutter（插件 LGPL-3.0；所用 Full GPL 变体含 GPL 组件，应用整体按 GPL-3.0 分发）\n'
      'PiliPlus（GPL-3.0-or-later）—— 哔哩哔哩接口解析参考实现\n'
      'bilibili-API-collect（CC-BY-NC 4.0）—— WBI 签名等接口文档，注意非商业限制\n'
      'Douyin_TikTok_Download_API（Apache-2.0）—— 抖音解析服务，仅通过 REST 调用\n'
      '其余 pub.dev 依赖遵循各自许可证\n\n'
      '本应用与哔哩哔哩、抖音无隶属关系，仅供学习研究；请仅下载你有权保存的内容。\n'
      '完整源码：https://github.com/42419/clipkeep',
    );
  });
  runApp(getRootWidget());
}
