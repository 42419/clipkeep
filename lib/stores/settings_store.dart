import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';

/// 应用设置（持久化到 shared_preferences）。
class SettingsStore extends ChangeNotifier {
  bool _saveToGallery = true;
  bool _dynamicColor = true;

  bool get saveToGallery => _saveToGallery;
  bool get dynamicColor => _dynamicColor;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _saveToGallery = prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
      _dynamicColor = prefs.getBool(AppConstants.prefDynamicColor) ?? true;
    } catch (_) {
      // 读取失败用默认值。
    }
    notifyListeners();
  }

  Future<void> setSaveToGallery(bool value) async {
    if (value == _saveToGallery) {
      return;
    }
    _saveToGallery = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.prefSaveToGallery, value);
    } catch (_) {
      // 写入失败忽略。
    }
  }

  Future<void> setDynamicColor(bool value) async {
    if (value == _dynamicColor) {
      return;
    }
    _dynamicColor = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.prefDynamicColor, value);
    } catch (_) {
      // 写入失败忽略。
    }
  }
}
