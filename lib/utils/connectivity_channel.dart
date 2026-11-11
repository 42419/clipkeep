import 'dart:async';

import 'package:flutter/services.dart';

/// 系统网络可用性事件（true = 有网）。
class ConnectivityChannel {
  ConnectivityChannel._();

  static const EventChannel _channel = EventChannel('clipkeep/connectivity');

  /// 订阅网络变化；测试或无宿主环境（EventChannel 未初始化）时返回 null。
  static StreamSubscription<bool>? listen(void Function(bool online) onData) {
    try {
      // 未初始化 binding 时 EventChannel 会在异步 onListen 里抛错，先探一下。
      ServicesBinding.instance;
      return _channel
          .receiveBroadcastStream()
          .map((dynamic value) => value == true)
          .listen(onData, onError: (Object _) {});
    } catch (_) {
      return null;
    }
  }
}
