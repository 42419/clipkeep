import 'package:flutter/foundation.dart';

/// 底部导航标签控制器，供各页切换 tab（如首页「全部」跳到下载页）。
class MainTabController extends ChangeNotifier {
  int _index = 0;
  int _downloadsSection = 0;

  int get index => _index;

  /// 下载页分段：0 进行中 / 1 已完成。
  int get downloadsSection => _downloadsSection;

  void select(int value) {
    if (value == _index) {
      return;
    }
    _index = value;
    notifyListeners();
  }

  /// 首页「全部」/最近下载：切到下载页并直接落在指定分段。
  void openDownloads({int section = 0}) {
    final int next = section.clamp(0, 1);
    final bool changed = _index != 1 || _downloadsSection != next;
    _index = 1;
    _downloadsSection = next;
    if (changed) {
      notifyListeners();
    }
  }

  void selectDownloads(int value) {
    final int next = value.clamp(0, 1);
    if (next == _downloadsSection) {
      return;
    }
    _downloadsSection = next;
    notifyListeners();
  }
}
