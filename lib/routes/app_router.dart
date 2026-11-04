import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../api/downloader_api.dart';
import '../pages/main_page.dart';
import '../stores/downloader_store.dart';
import '../theme/app_theme.dart';

/// 应用根 Widget：注入 Provider + M3E 主题 + 命名路由。
Widget getRootWidget() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DownloaderStore>(
        create: (_) => DownloaderStore(DownloaderApi()),
      ),
    ],
    child: M3EMaterialApp(
      title: 'ClipKeep',
      debugShowCheckedModeBanner: false,
      dynamicColoring: true,
      autoTheming: true,
      data: AppTheme.light(),
      home: const MainPage(),
      routes: getRootRoute(),
    ),
  );
}

/// 命名路由表（除根路由外的页面在此登记，如 '/settings'）。
/// 根页用 M3EMaterialApp.home，故这里不登记 '/'。
Map<String, WidgetBuilder> getRootRoute() {
  return <String, WidgetBuilder>{};
}
