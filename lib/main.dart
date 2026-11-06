import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

import 'routes/app_router.dart';

void main() {
  // 把 GPL 全文注册进 Flutter 的许可证页，APK 内可随时查看。
  LicenseRegistry.addLicense(() async* {
    final String text = await rootBundle.loadString(
      'assets/licenses/GPL-3.0.txt',
    );
    yield LicenseEntryWithLineBreaks(<String>['ClipKeep'], text);
  });
  runApp(getRootWidget());
}
