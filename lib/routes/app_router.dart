import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/downloader_api.dart';
import '../api/dtk_client.dart';
import '../pages/main_page.dart';
import '../stores/downloader_store.dart';
import '../stores/main_tab_controller.dart';
import '../stores/settings_store.dart';
import '../stores/update_store.dart';
import '../theme/app_theme.dart';
import '../theme/dynamic_color_host.dart';

/// 应用根 Widget：注入 Provider + Material 3 主题 + 命名路由。
Widget getRootWidget({SettingsStore? settingsStore, UpdateStore? updateStore}) {
  // 直接持有实例，避免 DownloaderStore 的闭包通过 context 跨 Provider 查找
  // SettingsStore（后者不是它的祖先，会抛 ProviderNotFoundException）。
  final SettingsStore store = settingsStore ?? (SettingsStore()..load());
  final UpdateStore updates = updateStore ?? UpdateStore();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsStore>.value(value: store),
      ChangeNotifierProvider<UpdateStore>.value(value: updates),
      ChangeNotifierProvider<DownloaderStore>(
        create: (_) => DownloaderStore(
          DownloaderApi(
            dtkConfig: () =>
                DtkConfig(baseUrl: store.dtkBaseUrl, apiKey: store.dtkApiKey),
          ),
          maxConcurrentProvider: () => store.maxConcurrent,
        ),
      ),
      ChangeNotifierProvider<MainTabController>(
        create: (_) => MainTabController(),
      ),
    ],
    child: Consumer<SettingsStore>(
      builder: (BuildContext context, SettingsStore settings, Widget? child) {
        return DynamicColorHost(
          enabled: settings.dynamicColor,
          builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
            return MaterialApp(
              title: 'ClipKeep',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(seedColor: lightDynamic?.primary),
              darkTheme: AppTheme.dark(seedColor: darkDynamic?.primary),
              themeMode: ThemeMode.system,
              home: const MainPage(),
              routes: getRootRoute(),
              builder: (BuildContext context, Widget? child) {
                final MediaQueryData media = MediaQuery.of(context);
                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.overlayStyle(Theme.of(context).brightness),
                  child: MediaQuery(
                    // 全应用 edge-to-edge：内容延伸到手势区，
                    // 各页用 viewPadding 自行补安全区。
                    data: media.copyWith(
                      padding: media.padding.copyWith(bottom: 0),
                    ),
                    child: child ?? const SizedBox.shrink(),
                  ),
                );
              },
            );
          },
        );
      },
    ),
  );
}

/// 命名路由表（除根路由外的页面在此登记，如 '/settings'）。
/// 根页用 MaterialApp.home，故这里不登记 '/'。
Map<String, WidgetBuilder> getRootRoute() {
  return <String, WidgetBuilder>{};
}
