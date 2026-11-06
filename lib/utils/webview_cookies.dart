import 'package:flutter/services.dart';

/// 与 Android 原生 CookieManager 通信：读取/清理 WebView 的 Cookie。
/// 登录页读取 Cookie 见 `bilibili_login_page`；这里只负责清理，供退出登录使用。
const MethodChannel _channel = MethodChannel('clipkeep/webview_cookie');

/// 清空本 App WebView 的全部 Cookie（含 HttpOnly）。
/// 失败时静默：退出登录不能因为原生异常而中断。
Future<void> clearWebViewCookies() async {
  try {
    await _channel.invokeMethod<void>('clearCookies');
  } catch (_) {
    // 原生通道不可用时忽略。
  }
}
