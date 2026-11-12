import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/update_service.dart';
import '../constants/app_constants.dart';
import '../utils/result.dart';

/// 检查更新状态：自动检查的节流、结果缓存与提示去重。
///
/// 只负责「查」和「记」，不关心怎么展示；页面通过 [hasUpdate] 与
/// [pendingPrompt] 决定提示方式。
class UpdateStore extends ChangeNotifier {
  UpdateStore({UpdateService? service, DateTime Function()? clock})
    : _service = service ?? UpdateService(),
      _clock = clock ?? DateTime.now;

  /// 自动检查间隔：一天一次。
  static const Duration checkInterval = Duration(hours: 24);

  /// 失败后的重试间隔，避免回前台时反复打网络。
  static const Duration retryGap = Duration(minutes: 30);

  final UpdateService _service;
  final DateTime Function() _clock;

  UpdateInfo? _latest;
  bool _checking = false;
  String? _error;
  String _currentVersion = '';
  int _currentCode = 0;
  DateTime? _lastCheckedAt;
  DateTime? _lastFailureAt;
  String? _promptedVersion;
  String? _ignoredVersion;

  /// 最近一次发现的最新版本名；即使本次进程没请求，重启后也能继续提示。
  String? _cachedLatestVersion;
  Future<void>? _loading;

  /// 最近一次成功的检查结果；失败时保留旧值，避免界面闪回。
  UpdateInfo? get latest => _latest;

  bool get checking => _checking;

  /// 最近一次检查的错误；自动检查失败时页面不展示，手动检查才展示。
  String? get error => _error;

  String get currentVersion => _currentVersion;

  int get currentCode => _currentCode;

  DateTime? get lastCheckedAt => _lastCheckedAt;

  /// 线上最新版本名；优先用本次结果，其次用上次缓存的版本名。
  String? get latestVersionName => _latest?.versionName ?? _cachedLatestVersion;

  /// 线上是否存在比本机更新的版本。
  ///
  /// 有完整结果时按 versionName + versionCode 比较；只有缓存版本名时
  /// （重启后 24 小时内还没重新请求）按版本名比较。
  bool get hasUpdate {
    if (_currentVersion.isEmpty) {
      return false;
    }
    final UpdateInfo? info = _latest;
    if (info != null) {
      return info.isNewerThan(_currentVersion, _currentCode);
    }
    final String? cached = _cachedLatestVersion;
    return cached != null && compareVersionNames(cached, _currentVersion) > 0;
  }

  /// 是否该提醒用户：有更新且没被主动忽略。
  ///
  /// 忽略只影响提醒，不影响 [hasUpdate] 的事实判断。
  bool get shouldNotify => hasUpdate && latestVersionName != _ignoredVersion;

  /// 当前被忽略的版本名；没有则为 null。
  String? get ignoredVersion => _ignoredVersion;

  /// 需要主动提示的版本；同一版本只提示一次。
  String? get pendingPrompt {
    if (!shouldNotify) {
      return null;
    }
    final String? version = latestVersionName;
    if (version == null || version == _promptedVersion) {
      return null;
    }
    return version;
  }

  /// 读本机版本与本地记录；重复调用只执行一次。
  Future<void> load() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      _currentCode = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      // 读不到版本就不做自动检查，避免误判。
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? millis = prefs.getInt(AppConstants.prefUpdateLastCheck);
      if (millis != null && millis > 0) {
        _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(millis);
      }
      _promptedVersion = prefs.getString(
        AppConstants.prefUpdatePromptedVersion,
      );
      _ignoredVersion = prefs.getString(AppConstants.prefUpdateIgnoredVersion);
      _cachedLatestVersion = prefs.getString(
        AppConstants.prefUpdateLatestVersion,
      );
    } catch (_) {
      // 本地记录读取失败按未检查处理。
    }
    notifyListeners();
  }

  /// 启动或回前台时调用：只在到期时请求。
  Future<void> checkIfDue() async {
    await load();
    if (_currentVersion.isEmpty) {
      return;
    }
    final DateTime now = _clock();
    final DateTime? last = _lastCheckedAt;
    if (last != null) {
      // 成功检查过：一天内不重复请求。
      if (now.difference(last) < checkInterval) {
        return;
      }
    } else {
      // 还没成功过：上次失败要等一小段时间，避免反复打网络。
      final DateTime? failedAt = _lastFailureAt;
      if (failedAt != null && now.difference(failedAt) < retryGap) {
        return;
      }
    }
    await check();
  }

  /// 主动检查（进入更新页或点「重新检查」时调用）。
  Future<void> check() async {
    if (_checking) {
      return;
    }
    await load();
    if (_currentVersion.isEmpty) {
      _error = '无法读取当前版本，请重试';
      notifyListeners();
      return;
    }
    _checking = true;
    _error = null;
    notifyListeners();
    final Result<UpdateInfo> result = await _service.check();
    if (result is Ok<UpdateInfo>) {
      _latest = result.value;
      _cachedLatestVersion = result.value.versionName;
      _lastCheckedAt = _clock();
      _lastFailureAt = null;
      unawaited(_persistLastCheck(_lastCheckedAt!));
      unawaited(_persistLatestVersion(result.value.versionName));
    } else if (result is Err<UpdateInfo>) {
      _error = result.error.message;
      _lastFailureAt = _clock();
    }
    _checking = false;
    notifyListeners();
  }

  /// 记录某版本已经提示过，之后不再自动弹。
  Future<void> markPrompted() async {
    final String? version = _latest?.versionName;
    if (version == null || version == _promptedVersion) {
      return;
    }
    _promptedVersion = version;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.prefUpdatePromptedVersion, version);
    } catch (_) {
      // 写入失败只影响下次提示去重。
    }
  }

  /// 忽略当前版本：不再弹提示、不再显示红点。
  Future<void> ignoreCurrent() async {
    final String? version = latestVersionName;
    if (version == null || version == _ignoredVersion) {
      return;
    }
    _ignoredVersion = version;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.prefUpdateIgnoredVersion, version);
    } catch (_) {
      // 写入失败只影响下次启动是否继续提醒。
    }
  }

  /// 恢复对已忽略版本的提醒。
  Future<void> clearIgnored() async {
    if (_ignoredVersion == null) {
      return;
    }
    _ignoredVersion = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.prefUpdateIgnoredVersion);
    } catch (_) {
      // 写入失败忽略。
    }
  }

  Future<void> _persistLatestVersion(String version) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.prefUpdateLatestVersion, version);
    } catch (_) {
      // 写入失败只影响重启后的红点。
    }
  }

  Future<void> _persistLastCheck(DateTime time) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        AppConstants.prefUpdateLastCheck,
        time.millisecondsSinceEpoch,
      );
    } catch (_) {
      // 写入失败只影响节流。
    }
  }
}
