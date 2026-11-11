import 'package:flutter/services.dart';

/// 下载前台服务/通知通道；测试环境或原生缺失时静默失败。
class DownloadNotifications {
  DownloadNotifications._();

  static const MethodChannel _channel = MethodChannel(
    'clipkeep/downloads_service',
  );

  static Future<void> ensurePermission() => _invoke('ensurePermission');

  static Future<void> start({
    required String title,
    required String text,
    int progress = 0,
    bool indeterminate = false,
  }) => _invoke('start', <String, Object>{
    'title': title,
    'text': text,
    'progress': progress,
    'indeterminate': indeterminate,
  });

  static Future<void> update({
    required String title,
    required String text,
    int progress = 0,
    bool indeterminate = false,
  }) => _invoke('update', <String, Object>{
    'title': title,
    'text': text,
    'progress': progress,
    'indeterminate': indeterminate,
  });

  static Future<void> complete({required String title, required String text}) =>
      _invoke('complete', <String, Object>{'title': title, 'text': text});

  static Future<void> stop() => _invoke('stop');

  static Future<void> _invoke(
    String method, [
    Map<String, Object>? args,
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // 原生不可用时不影响下载本身。
    }
  }
}
