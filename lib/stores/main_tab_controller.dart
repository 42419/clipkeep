import 'package:flutter/foundation.dart';

/// 底部导航标签控制器，供各页切换 tab（如首页「全部」跳到下载页）。
class MainTabController extends ChangeNotifier {
  int _index = 0;

  int get index => _index;

  void select(int value) {
    if (value == _index) {
      return;
    }
    _index = value;
    notifyListeners();
  }
}
