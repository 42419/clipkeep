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
  final Map<String, Future<void>> _running = <String, Future<void>>{};
  final Completer<void> _historyReady = Completer<void>();

  bool _parsing = false;
  String? _error;
  ParsedSource? _source;
  String? _savedMessage;
  int _parseSeq = 0;
  int _partIndex = 0;
  bool _partLoading = false;

  bool get parsing => _parsing;
  String? get error => _error;
  ParsedSource? get source => _source;
  String? get savedMessage => _savedMessage;
  int get partIndex => _partIndex;
  bool get partLoading => _partLoading;

  String? _lastInput;

  String? get lastInput => _lastInput;

  Future<void> retry() async {
    final String? input = _lastInput;
    if (input != null) {
      await parse(input);
    }
  }

  Future<void> parse(String input) async {
    final int seq = ++_parseSeq;
    _lastInput = input;
    _parsing = true;
    _error = null;
    _savedMessage = null;
    notifyListeners();
    final Result<ParsedSource> result = await _api.parse(
      input,
      cookie: cookieProvider?.call(),
    );
    // 期间又发起了新的解析：丢弃这次的结果，避免旧请求覆盖新内容。
    if (seq != _parseSeq) {
      return;
    }
    if (result is Ok<ParsedSource>) {
      _source = result.value;
      _partIndex = result.value.parts.isEmpty
          ? 0
          : result.value.initialPartIndex.clamp(
              0,
              result.value.parts.length - 1,
            );
    } else if (result is Err<ParsedSource>) {
      _source = null;
      _error = result.error.message;
    }
    _parsing = false;
    _partLoading = false;
    notifyListeners();
  }

  /// 按需加载某个分 P 的 DASH 流；只请求当前 P，避免一次性打满 playurl。
  Future<Result<MediaPart>> selectPart(int index) async {
    final ParsedSource? source = _source;
    if (source == null || index < 0 || index >= source.parts.length) {
      return const Err(AppError('分 P 不存在'));
    }
    if (_partLoading) {
      return const Err(AppError('正在加载分 P，请稍候'));
    }
    final MediaPart part = source.parts[index];
    if (part.streams.isNotEmpty) {
      _partIndex = index;
      notifyListeners();
      return Ok<MediaPart>(part);
    }
    _partLoading = true;
    notifyListeners();
    try {
      final Result<List<MediaStream>> refreshed = await _api.refreshStreams(
        part,
        cookie: cookieProvider?.call(),
      );
      if (refreshed is Ok<List<MediaStream>> && refreshed.value.isNotEmpty) {
        final MediaPart loaded = MediaPart(
          id: part.id,
          title: part.title,
          durationSeconds: part.durationSeconds,
          streams: refreshed.value,
        );
        source.parts[index] = loaded;
        _partIndex = index;
        return Ok<MediaPart>(loaded);
      }
      return const Err(AppError('该分 P 暂时无法获取画质，请稍后重试'));
    } finally {
      _partLoading = false;
      notifyListeners();
    }
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
    String? sourceUrl,
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
      sourceUrl: sourceUrl,
    );
    _tasks.insert(0, task);
    unawaited(_persistCompleted());
    notifyListeners();
    _startRun(task);
    return task;
  }

  /// 保存图文/图集：直接落盘，完成后写入一条已完成记录。
  Future<Result<String>> saveImages(
    ParsedSource source, {
    int? onlyIndex,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final String downloadId = 'img_${DateTime.now().microsecondsSinceEpoch}';
    final int? index = onlyIndex?.clamp(0, source.images.length - 1);
    final Result<String> result = await _api.saveImages(
      source.images,
      onlyIndex: index,
      downloadId: downloadId,
      onProgress: onProgress,
    );
    if (result is Ok<String>) {
      final List<MediaImage> saved = index == null
          ? source.images
          : <MediaImage>[source.images[index]];
      final int liveCount = saved.where((MediaImage e) => e.isLive).length;
      final DownloadTask task = DownloadTask(
        id: downloadId,
        title: source.title,
        platform: source.platformLabel,
        qualityLabel:
            '图文 · ${saved.length} 张${liveCount > 0 ? ' · $liveCount 实况' : ''}',
        createdAt: DateTime.now(),
        status: DownloadStatus.completed,
        progress: 1,
        coverUrl: saved.isNotEmpty ? saved.first.primaryUrl : source.coverUrl,
        sourceUrl: source.sourceUrl,
        savedMessage: result.value,
      );
      _tasks.insert(0, task);
      notifyListeners();
      unawaited(_persistCompleted());
    }
    return result;
  }

  /// 启动一次下载运行。同一任务在同一时刻只允许一个运行，避免两次运行
  /// 同时向同一个临时文件追加数据、互相覆盖状态。
  void _startRun(DownloadTask task) {
    if (_running.containsKey(task.id)) {
      return;
    }
    final Future<void> run = _runTask(task);
    _running[task.id] = run;
    run.whenComplete(() {
      if (identical(_running[task.id], run)) {
        _running.remove(task.id);
      }
    }).ignore();
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
    task.phase = null;
    task.speedBytesPerSec = 0;
    notifyListeners();

    // 同一次运行内进度只增不减：音频流稍晚注册时总字节会变大，避免进度条回退。
    double runProgress = task.progress;
    final Result<String> result = await _api.download(
      part,
      videoQuality: task.videoQuality,
      audioOnly: task.audioOnly,
      coverOnly: task.coverOnly,
      saveCover: task.saveCover,
      coverUrl: task.coverUrl,
      cookie: cookieProvider?.call(),
      downloadId: task.id,
      cancelToken: token,
      onProgress: (DownloadProgress p) {
        if (!identical(_tokens[task.id], token) ||
            task.status != DownloadStatus.downloading) {
          return;
        }
        if (p.fraction > runProgress) {
          runProgress = p.fraction;
        }
        task.progress = runProgress;
        task.receivedBytes = p.receivedBytes;
        task.totalBytes = p.totalBytes;
        task.speedBytesPerSec = p.speedBytesPerSec;
        task.phase = p.phase;
        notifyListeners();
      },
    );
    if (identical(_tokens[task.id], token)) {
      _tokens.remove(task.id);
    }
    // 任务已被删除：不再写回任何状态。
    if (!_tasks.contains(task)) {
      return;
    }
    if (task.status == DownloadStatus.paused) {
      notifyListeners();
      return;
    }
    if (result is Ok<String>) {
      task.status = DownloadStatus.completed;
      task.progress = 1;
      task.phase = null;
      task.savedMessage = result.value;
      final String? thumb = await _api.cacheCover(task.coverUrl, task.id);
      if (_tasks.contains(task)) {
        task.thumbnailPath = thumb;
      }
    } else if (result is Err<String>) {
      task.phase = null;
      task.status = DownloadStatus.failed;
      task.error = result.error.message;
    }
    unawaited(_persistCompleted());
    notifyListeners();
  }

  void pauseTask(DownloadTask task) {
    if (task.status != DownloadStatus.downloading) {
      return;
    }
    task.status = DownloadStatus.paused;
    _tokens[task.id]?.cancel('paused');
    unawaited(_persistCompleted());
    notifyListeners();
  }

  /// 继续暂停/失败的任务。先等上一次运行彻底结束（Dio 取消是异步的），
  /// 再启动新运行，避免两个运行同时写同一个临时文件。
  Future<void> resumeTask(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading || task.part == null) {
      return;
    }
    // 重启后恢复的任务没有签名 URL：先重新拉流，再续传。
    if (task.part!.streams.isEmpty) {
      await retryTask(task);
      return;
    }
    final Future<void>? previous = _running[task.id];
    if (previous != null) {
      await previous;
    }
    if (!_tasks.contains(task)) {
      return;
    }
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    _startRun(task);
  }

  /// 重试失败任务：先用最新地址刷新流（解决签名 URL 过期 403），再继续下载。
  Future<void> retryTask(DownloadTask task) async {
    if (_running.containsKey(task.id)) {
      return;
    }
    final MediaPart? part = task.part;
    if (part != null) {
      final Result<List<MediaStream>> refreshed = await _api.refreshStreams(
        part,
        cookie: cookieProvider?.call(),
      );
      if (refreshed is Ok<List<MediaStream>> && refreshed.value.isNotEmpty) {
        task.part = MediaPart(
          id: part.id,
          title: part.title,
          durationSeconds: part.durationSeconds,
          streams: refreshed.value,
        );
      } else {
        task
          ..status = DownloadStatus.failed
          ..error = '刷新下载地址失败，请稍后重试';
        unawaited(_persistCompleted());
        notifyListeners();
        return;
      }
    }
    // 重试可能因签名/分片失效而从零开始，先清掉旧进度，避免停在虚假的百分比。
    task.progress = 0;
    await resumeTask(task);
  }

  void removeTask(DownloadTask task) {
    _tokens[task.id]?.cancel('removed');
    _tokens.remove(task.id);
    unawaited(_deleteThumbQuietly(task.thumbnailPath));
    // 删除记录时清掉临时文件；失败任务的文件在删除前保留，供重试续传。
    // 等当前运行收尾后再删，否则可能边写边删、留下残留分片。
    final Future<void>? previous = _running[task.id];
    if (previous == null) {
      unawaited(_api.cleanup(task.id));
    } else {
      // ignore()：即使上一次运行以异常结束，清理仍要执行且不能产生未捕获错误。
      previous.whenComplete(() => _api.cleanup(task.id)).ignore();
    }
    _tasks.remove(task);
    unawaited(_persistCompleted());
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    await _historyReady.future;
    final List<DownloadTask> completed = _tasks
        .where((DownloadTask t) => t.isCompleted)
        .toList();
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
      final String? raw =
          prefs.getString('download_tasks') ??
          prefs.getString('download_history');
      if (raw == null || raw.isEmpty) {
        unawaited(_api.cleanupOrphans(<String>{}));
        return;
      }
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      for (final dynamic item in list) {
        try {
          final DownloadTask task = DownloadTask.fromRecord(
            (item as Map).cast<String, dynamic>(),
          );
          if (!_tasks.any((DownloadTask t) => t.id == task.id)) {
            _tasks.add(task);
          }
        } catch (_) {
          // 单条坏记录跳过，避免整批历史丢失。
        }
      }
      notifyListeners();
      final Set<String> activeIds = _tasks
          .where((DownloadTask t) => !t.isCompleted)
          .map((DownloadTask t) => t.id)
          .toSet();
      unawaited(_api.cleanupOrphans(activeIds));
    } catch (_) {
      // 读取历史失败忽略。
    } finally {
      if (!_historyReady.isCompleted) {
        _historyReady.complete();
      }
    }
  }

  Future<void> _persistCompleted() async {
    // 冷启动加载完成前不要覆写历史，否则新任务可能把旧记录挤掉。
    await _historyReady.future;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // 保留全部任务：未完成的在重启后仍可继续/删除。
      final List<Map<String, dynamic>> list = _tasks
          .map((DownloadTask t) => t.toRecord())
          .toList();
      await prefs.setString('download_tasks', jsonEncode(list));
    } catch (_) {
      // 写入失败忽略。
    }
  }
}
