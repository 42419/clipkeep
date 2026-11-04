import 'package:flutter/foundation.dart';

import '../../../../core/result.dart';
import '../../domain/entities/parsed_source.dart';
import '../../domain/repositories/downloader_repository.dart';

class DownloaderController extends ChangeNotifier {
  DownloaderController(this._repository);

  final DownloaderRepository _repository;

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
    final result = await _repository.parse(input);
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
    final result = await _repository.download(part, onProgress: (p) {
      _progress = p;
      notifyListeners();
    });
    if (result is Ok<String>) {
      _savedMessage = '已保存到相册：${result.value}';
    } else if (result is Err<String>) {
      _error = result.error.message;
    }
    _downloading = false;
    notifyListeners();
  }
}
