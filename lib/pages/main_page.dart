import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'downloads/downloads_view.dart';
import 'home/home_view.dart';
import 'settings/settings_view.dart';

/// 底部三页外壳：首页 / 下载 / 设置。
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[HomeView(), DownloadsView(), SettingsView()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int value) => setState(() => _index = value),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '首页',
            tooltip: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download_rounded),
            label: '下载',
            tooltip: '下载',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: '设置',
            tooltip: '设置',
          ),
        ],
      ),
    );
  }
}
