import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/common/clipboard_link_sheet.dart';
import '../stores/downloader_store.dart';
import '../stores/main_tab_controller.dart';
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
  static final RegExp _biliPattern = RegExp(
    r'(bilibili\.com|b23\.tv|bili2233\.cn|BV[0-9A-Za-z]{10}|douyin\.com|iesdouyin\.com)',
  );

  String? _lastClipboard;
  bool _sheetShowing = false;
  bool _openingResult = false;
  bool _prefsLoaded = false;
  bool _autoDetect = true;

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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkClipboard());
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
    if (!_autoDetect) {
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
    if (!_biliPattern.hasMatch(text)) {
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
      autoDetect: _autoDetect,
      onAutoDetectChanged: _setAutoDetect,
      onParse: () => _parseFromClipboard(text),
    );
    _sheetShowing = false;
  }

  Future<void> _ensureLoaded() async {
    if (_prefsLoaded) {
      return;
    }
    _prefsLoaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _lastClipboard = prefs.getString('clipboard_last');
      _autoDetect = prefs.getBool('clipboard_auto') ?? true;
    } catch (_) {
      // 读取失败忽略，仅影响跨启动去重/开关。
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

  void _setAutoDetect(bool value) {
    setState(() => _autoDetect = value);
    unawaited(_persistAutoDetect(value));
  }

  Future<void> _persistAutoDetect(bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('clipboard_auto', value);
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
    return Scaffold(
      body: IndexedStack(
        index: tab.index,
        children: const <Widget>[HomeView(), DownloadsView(), SettingsView()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.index,
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
    );
  }
}
