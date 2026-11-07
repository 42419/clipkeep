import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../api/downloader_api.dart';
import '../api/dtk_client.dart';
import '../pages/main_page.dart';
import '../stores/auth_store.dart';
import '../stores/downloader_store.dart';
import '../stores/main_tab_controller.dart';
import '../stores/settings_store.dart';
import '../theme/app_theme.dart';

/// 应用根 Widget：注入 Provider + M3E 主题 + 命名路由。
Widget getRootWidget({SettingsStore? settingsStore}) {
  // 直接持有实例，避免 DownloaderStore 的闭包通过 context 跨 Provider 查找
  // SettingsStore（后者不是它的祖先，会抛 ProviderNotFoundException）。
  final SettingsStore store = settingsStore ?? (SettingsStore()..load());
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthStore>(create: (_) => AuthStore()..load()),
      ChangeNotifierProvider<SettingsStore>.value(value: store),
      ChangeNotifierProvider<DownloaderStore>(
        create: (BuildContext ctx) => DownloaderStore(
          DownloaderApi(
            dtkConfig: () =>
                DtkConfig(baseUrl: store.dtkBaseUrl, apiKey: store.dtkApiKey),
          ),
          cookieProvider: () => ctx.read<AuthStore>().cookie,
        ),
      ),
      ChangeNotifierProvider<MainTabController>(
        create: (_) => MainTabController(),
      ),
    ],
    child: Consumer<SettingsStore>(
      builder: (BuildContext context, SettingsStore settings, Widget? child) {
        return M3EMaterialApp(
          title: 'ClipKeep',
          debugShowCheckedModeBanner: false,
          dynamicColoring: settings.dynamicColor,
          autoTheming: true,
          // 全应用 edge-to-edge：背景延伸到状态栏/导航栏下方，
          // 内容由各页 SafeArea 与 NavigationBar 的 viewPadding 保护。
          drawUnderSystemBars: true,
          data: AppTheme.light(),
          home: const MainPage(),
          routes: getRootRoute(),
        );
      },
    ),
  );
}

/// 命名路由表（除根路由外的页面在此登记，如 '/settings'）。
/// 根页用 M3EMaterialApp.home，故这里不登记 '/'。
Map<String, WidgetBuilder> getRootRoute() {
  return <String, WidgetBuilder>{};
}
