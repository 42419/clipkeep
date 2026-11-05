import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/downloader_api.dart';
import '../utils/result.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';

/// 状态管理（Provider + ChangeNotifier）：解析 + 下载任务列表。
class DownloaderStore extends ChangeNotifier {
  DownloaderStore(this._api, {this.cookieProvider}) {
    unawaited(_loadHistory());
  }

  final DownloaderApi _api;
  final String? Function()? cookieProvider;
  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};

  bool _parsing = false;
  String? _error;
  ParsedSource? _source;
  String? _savedMessage;

  bool get parsing => _parsing;
  String? get error => _error;
  ParsedSource? get source => _source;
  String? get savedMessage => _savedMessage;

  String? _lastInput;

  String? get lastInput => _lastInput;

  Future<void> retry() async {
    final String? input = _lastInput;
    if (input != null) {
      await parse(input);
    }
  }

  Future<void> parse(String input) async {
    _lastInput = input;
    _parsing = true;
    _error = null;
    _savedMessage = null;
    notifyListeners();
    final Result<ParsedSource> result = await _api.parse(
      input,
      cookie: cookieProvider?.call(),
    );
    if (result is Ok<ParsedSource>) {
      _source = result.value;
    } else if (result is Err<ParsedSource>) {
      _source = null;
      _error = result.error.message;
    }
    _parsing = false;
    notifyListeners();
  }

  // ---------- 下载任务 ----------
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  List<DownloadTask> get activeTasks => _tasks
      .where(
        (DownloadTask t) =>
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.paused ||
            t.status == DownloadStatus.failed,
      )
      .toList();

  List<DownloadTask> get completedTasks =>
      _tasks.where((DownloadTask t) => t.isCompleted).toList();

  int get activeCount => activeTasks.length;

  int get completedCount => completedTasks.length;

  DownloadTask? taskById(String id) {
    for (final DownloadTask task in _tasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  DownloadTask startDownload(
    MediaPart part, {
    required String title,
    String platform = '哔哩哔哩',
    required String qualityLabel,
    int? videoQuality,
    bool audioOnly = false,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
  }) {
    final DownloadTask task = DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      platform: platform,
      qualityLabel: qualityLabel,
      part: part,
      createdAt: DateTime.now(),
      videoQuality: videoQuality,
      audioOnly: audioOnly,
      coverOnly: coverOnly,
      saveCover: saveCover,
      coverUrl: coverUrl,
    );
    _tasks.insert(0, task);
    notifyListeners();
    unawaited(_runTask(task));
    return task;
  }

  Future<void> _runTask(DownloadTask task) async {
    final MediaPart? part = task.part;
    if (part == null) {
      return;
    }
    final CancelToken token = CancelToken();
    _tokens[task.id] = token;
    task.status = DownloadStatus.downloading;
    task.error = null;
    task.savedMessage = null;
    task.progress = 0;
    task.receivedBytes = 0;
    task.totalBytes = 0;
    task.speedBytesPerSec = 0;
    notifyListeners();

    final Result<String> result = await _api.download(
      part,
      videoQuality: task.videoQuality,
      audioOnly: task.audioOnly,
      coverOnly: task.coverOnly,
      saveCover: task.saveCover,
      coverUrl: task.coverUrl,
      cookie: cookieProvider?.call(),
      cancelToken: token,
      onProgress: (DownloadProgress p) {
        task.progress = p.fraction;
        task.receivedBytes = p.receivedBytes;
        task.totalBytes = p.totalBytes;
        task.speedBytesPerSec = p.speedBytesPerSec;
        task.phase = p.phase;
        notifyListeners();
      },
    );
    _tokens.remove(task.id);
    if (task.status == DownloadStatus.paused) {
      notifyListeners();
      return;
    }
    if (result is Ok<String>) {
      task.status = DownloadStatus.completed;
      task.progress = 1;
      task.phase = null;
      task.savedMessage = result.value;
      task.thumbnailPath = await _api.cacheCover(task.coverUrl, task.id);
      unawaited(_persistCompleted());
    } else if (result is Err<String>) {
      task.phase = null;
      task.status = DownloadStatus.failed;
      task.error = result.error.message;
    }
    notifyListeners();
  }

  void pauseTask(DownloadTask task) {
    if (task.status != DownloadStatus.downloading) {
      return;
    }
    task.status = DownloadStatus.paused;
    _tokens[task.id]?.cancel('paused');
    notifyListeners();
  }

  void resumeTask(DownloadTask task) {
    if (task.status == DownloadStatus.downloading || task.part == null) {
      return;
    }
    unawaited(_runTask(task));
  }

  void retryTask(DownloadTask task) => resumeTask(task);

  void removeTask(DownloadTask task) {
    _tokens[task.id]?.cancel('removed');
    _tokens.remove(task.id);
    unawaited(_deleteThumbQuietly(task.thumbnailPath));
    _tasks.remove(task);
    unawaited(_persistCompleted());
    notifyListeners();
  }

  void clearCompleted() {
    final List<DownloadTask> completed =
        _tasks.where((DownloadTask t) => t.isCompleted).toList();
    for (final DownloadTask task in completed) {
      unawaited(_deleteThumbQuietly(task.thumbnailPath));
    }
    _tasks.removeWhere((DownloadTask t) => t.isCompleted);
    unawaited(_persistCompleted());
    notifyListeners();
  }

  Future<void> _deleteThumbQuietly(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    try {
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 忽略缓存清理失败。
    }
  }

  Future<void> _loadHistory() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('download_history');
      if (raw == null || raw.isEmpty) {
        return;
      }
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      for (final dynamic item in list) {
        final DownloadTask task =
            DownloadTask.fromRecord((item as Map).cast<String, dynamic>());
        if (!_tasks.any((DownloadTask t) => t.id == task.id)) {
          _tasks.add(task);
        }
      }
      notifyListeners();
    } catch (_) {
      // 读取历史失败忽略。
    }
  }

  Future<void> _persistCompleted() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> list = _tasks
          .where((DownloadTask t) => t.isCompleted)
          .map((DownloadTask t) => t.toRecord())
          .toList();
      await prefs.setString('download_history', jsonEncode(list));
    } catch (_) {
      // 写入失败忽略。
    }
  }
}
