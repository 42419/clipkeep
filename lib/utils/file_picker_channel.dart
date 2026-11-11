import 'package:flutter/services.dart';

/// 调用 Android 系统文件选择器（SAF）；用户取消时返回 null。
class FilePickerChannel {
  FilePickerChannel._();

  static const MethodChannel _channel = MethodChannel('clipkeep/file_picker');

  static Future<String?> pickImage() => _pick('pickImage');

  static Future<String?> pickVideo() => _pick('pickVideo');

  static Future<String?> _pick(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
    } on PlatformException catch (e) {
      throw FilePickException(e.message ?? '选择文件失败');
    } on MissingPluginException {
      throw const FilePickException('当前版本不支持选择本地文件');
    }
  }
}

class FilePickException implements Exception {
  const FilePickException(this.message);

  final String message;

  @override
  String toString() => message;
}
