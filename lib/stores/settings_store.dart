import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';

/// 应用设置（普通项存 shared_preferences，密钥存安全存储）。
class SettingsStore extends ChangeNotifier {
  SettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  bool _saveToGallery = true;
  bool _dynamicColor = true;
  String _dtkBaseUrl = AppConstants.dtkBaseUrl;
  String _dtkApiKey = AppConstants.dtkApiKey;

  bool get saveToGallery => _saveToGallery;
  bool get dynamicColor => _dynamicColor;
  String get dtkBaseUrl => _dtkBaseUrl;
  String get dtkApiKey => _dtkApiKey;
  bool get dtkConfigured =>
      _dtkBaseUrl.trim().isNotEmpty && _dtkApiKey.trim().isNotEmpty;

  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _saveToGallery = prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
      _dynamicColor = prefs.getBool(AppConstants.prefDynamicColor) ?? true;
      final String? base = prefs.getString(AppConstants.prefDtkBaseUrl);
      // 空串是用户主动清空的结果，不能回退到内置默认值。
      if (base != null) {
        _dtkBaseUrl = base;
      }
    } catch (_) {
      // 读取失败用默认值。
    }
    try {
      final String? storedKey = await _storage.read(
        key: AppConstants.secureDtkApiKey,
      );
      // 同上：空串表示已清空，不能把内置 Key 又填回来。
      if (storedKey != null) {
        _dtkApiKey = storedKey;
      }
    } catch (_) {
      // 安全存储读取失败按空处理。
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
    } catch (_) {}
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
    } catch (_) {}
  }

  Future<void> setDtkBaseUrl(String value) async {
    final String v = value.trim();
    if (v == _dtkBaseUrl) {
      return;
    }
    _dtkBaseUrl = v;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.prefDtkBaseUrl, v);
    } catch (_) {}
  }

  Future<void> setDtkApiKey(String value) async {
    final String v = value.trim();
    if (v == _dtkApiKey) {
      return;
    }
    _dtkApiKey = v;
    notifyListeners();
    try {
      await _storage.write(key: AppConstants.secureDtkApiKey, value: v);
    } catch (_) {}
  }
}
