import 'package:flutter/foundation.dart';

import '../api/downloader_api.dart';
import '../utils/result.dart';
import '../viewmodels/parsed_source.dart';

/// 状态管理（Provider + ChangeNotifier）。
class DownloaderStore extends ChangeNotifier {
  DownloaderStore(this._api);

  final DownloaderApi _api;

  bool _parsing = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;
  ParsedSource? _source;
  String? _savedMessage;

  bool get parsing => _parsing;
  bool get downloading => _downloading;
  double get progress => _progress;
  String? get error => _error;
  ParsedSource? get source => _source;
  String? get savedMessage => _savedMessage;

  Future<void> parse(String input) async {
    _parsing = true;
    _error = null;
    _savedMessage = null;
    notifyListeners();
    final result = await _api.parse(input);
    if (result is Ok<ParsedSource>) {
      _source = result.value;
    } else if (result is Err<ParsedSource>) {
      _source = null;
      _error = result.error.message;
    }
    _parsing = false;
    notifyListeners();
  }

  Future<void> download(MediaPart part) async {
    _downloading = true;
    _progress = 0;
    _error = null;
    _savedMessage = null;
    notifyListeners();
    final result = await _api.download(part, onProgress: (p) {
      _progress = p;
      notifyListeners();
    });
    if (result is Ok<String>) {
      _savedMessage = '已保存到相册（ClipKeep）';
    } else if (result is Err<String>) {
      _error = result.error.message;
    }
    _downloading = false;
    notifyListeners();
  }
}
