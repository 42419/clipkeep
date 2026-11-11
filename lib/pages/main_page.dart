import 'dart:async';

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, SystemNavigator;
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/common/clipboard_link_sheet.dart';
import '../stores/downloader_store.dart';
import '../stores/main_tab_controller.dart';
import '../stores/settings_store.dart';
import 'downloads/downloads_view.dart';
import 'home/home_view.dart';
import 'result_page.dart';
import 'settings/settings_view.dart';

/// 底部三页外壳：首页 / 下载 / 设置。同时在进入/回到前台时检测剪贴板。
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
  static final RegExp _douyinPattern = RegExp(r'(douyin\.com|iesdouyin\.com)');

  String? _lastClipboard;
  bool _sheetShowing = false;
  bool _openingResult = false;
  bool _prefsLoaded = false;
  final PageController _pageController = PageController();
  MainTabController? _tabs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 稍等窗口获得焦点（Android 10+ 未聚焦时读剪贴板会返回空）。
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _ensureLoaded();
      if (mounted) {
        await _checkClipboard();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MainTabController tabs = context.read<MainTabController>();
    if (!identical(_tabs, tabs)) {
      _tabs?.removeListener(_onTabChanged);
      _tabs = tabs..addListener(_onTabChanged);
    }
  }

  /// 底部导航切页用横向滑动，而不是瞬切。
  void _onTabChanged() {
    final int index = _tabs?.index ?? 0;
    if (!_pageController.hasClients) {
      return;
    }
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  @override
  void dispose() {
    _tabs?.removeListener(_onTabChanged);
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkClipboardAfterResume());
    }
  }

  /// 回前台时窗口未必已获得焦点，Android 10+ 首次读剪贴板常为空；
  /// 延迟后重试一次，避免“复制后切回来不弹窗”。
  Future<void> _checkClipboardAfterResume() async {
    final SettingsStore settings = context.read<SettingsStore>();
    if (!settings.clipboardAuto) {
      return;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      await Future<void>.delayed(
        Duration(milliseconds: attempt == 0 ? 350 : 500),
      );
      if (!mounted) {
        return;
      }
      await _checkClipboard();
      if (_sheetShowing) {
        return;
      }
    }
  }

  Future<void> _checkClipboard() async {
    if (!mounted || _sheetShowing) {
      return;
    }
    await _ensureLoaded();
    if (!mounted) {
      return;
    }
    final SettingsStore settings = context.read<SettingsStore>();
    if (!settings.clipboardAuto) {
      return;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return;
    }
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return;
    }
    final String? text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      return;
    }
    if (!_douyinPattern.hasMatch(text)) {
      return;
    }
    final RegExpMatch? urlMatch = _urlPattern.firstMatch(text);
    final String link = urlMatch?.group(0) ?? text;
    // 去重：同一链接已处理过（含跨启动）就不再弹。
    if (link == _lastClipboard) {
      return;
    }
    _lastClipboard = link;
    unawaited(_persistLastHandled(link));
    if (!mounted) {
      return;
    }
    _sheetShowing = true;
    await showClipboardLinkSheet(
      context,
      link: link,
      autoDetect: settings.clipboardAuto,
      onAutoDetectChanged: (bool value) =>
          unawaited(settings.setClipboardAuto(value)),
      onParse: () => _parseFromClipboard(text),
    );
    _sheetShowing = false;
  }

  Future<void> _ensureLoaded() async {
    if (_prefsLoaded) {
      return;
    }
    _prefsLoaded = true;
    // 保证从设置页关闭自动检测后，冷启动也不会用默认 true 弹一次。
    final SettingsStore settings = context.read<SettingsStore>();
    if (!settings.isLoaded) {
      await settings.load();
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _lastClipboard = prefs.getString('clipboard_last');
    } catch (_) {
      // 读取失败忽略，仅影响跨启动去重。
    }
  }

  Future<void> _persistLastHandled(String value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('clipboard_last', value);
    } catch (_) {
      // 写入失败忽略。
    }
  }

  Future<void> _parseFromClipboard(String text) async {
    if (_openingResult) {
      return;
    }
    _openingResult = true;
    try {
      final DownloaderStore store = context.read<DownloaderStore>();
      unawaited(store.parse(text));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const ResultPage(),
        ),
      );
    } finally {
      _openingResult = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final MainTabController tab = context.watch<MainTabController>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        if (tab.index != 0) {
          tab.select(0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: const <Widget>[
            _KeepAlivePage(child: HomeView()),
            _KeepAlivePage(child: DownloadsView()),
            _KeepAlivePage(child: SettingsView()),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          // drawUnderSystemBars 会清掉 MediaQuery.padding.bottom，
          // 必须用 viewPadding 才能把图标抬到手势条上方。
          maintainBottomViewPadding: true,
          onDestinationSelected: tab.select,
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
      ),
    );
  }
}

/// PageView 默认会销毁离屏页面；用 KeepAlive 保住各页的滚动位置与输入内容。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
