import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/downloader_api.dart';
import '../utils/connectivity_channel.dart';
import '../utils/download_notifications.dart';
import '../utils/format.dart';
import '../utils/media_naming.dart';
import '../utils/result.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';

/// 状态管理（Provider + ChangeNotifier）：解析 + 下载任务列表。
class DownloaderStore extends ChangeNotifier {
  DownloaderStore(this._api, {this.maxConcurrentProvider}) {
    unawaited(_loadHistory());
    ConnectivityChannel.listen(_onNetworkChanged);
  }

  final DownloaderApi _api;

  /// 同时下载数由设置页控制；缺省 2。
  final int Function()? maxConcurrentProvider;
  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Map<String, Future<void>> _running = <String, Future<void>>{};
  final Set<String> _retrying = <String>{};
  final Map<String, int> _autoRetries = <String, int>{};
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  bool _serviceRunning = false;
  bool _hadActiveTask = false;
  DateTime _lastServiceUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DownloadTask? _lastCompletedTask;
  DateTime _lastNetworkRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Completer<void> _historyReady = Completer<void>();

  bool _parsing = false;
  String? _error;
  ParsedSource? _source;
  int _idSeq = 0;
  String? _savedMessage;
  int _parseSeq = 0;

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
    final int seq = ++_parseSeq;
    _lastInput = input;
    _parsing = true;
    _error = null;
    _savedMessage = null;
    notifyListeners();
    final Result<ParsedSource> result = await _api.parse(input);
    // 期间又发起了新的解析：丢弃这次的结果，避免旧请求覆盖新内容。
    if (seq != _parseSeq) {
      return;
    }
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
            t.status == DownloadStatus.queued ||
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

  String _nextId() => '${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';

  DownloadTask startDownload(
    MediaPart part, {
    required String title,
    String platform = '抖音',
    required String qualityLabel,
    int? videoQuality,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    String? sourceUrl,
    ParsedSource? source,
  }) {
    final MediaStream? stream = part.pickVideoQuality(videoQuality);
    final String stem = buildVideoStem(
      title: source?.title ?? title,
      author: source?.author,
      publishedAt: source?.publishDate,
      contentId: contentIdOf(part.id),
      resolution: coverOnly
          ? null
          : stream?.displayLabel ??
                (videoQuality != null ? _qualityText(videoQuality) : null),
      fps: stream?.fps,
    );
    final DownloadTask task = DownloadTask(
      id: _nextId(),
      title: title,
      platform: platform,
      qualityLabel: qualityLabel,
      part: part,
      createdAt: DateTime.now(),
      videoQuality: videoQuality,
      coverOnly: coverOnly,
      saveCover: saveCover,
      coverUrl: coverUrl,
      sourceUrl: sourceUrl,
      fileStem: stem,
      status: DownloadStatus.queued,
    );
    _tasks.insert(0, task);
    unawaited(_persistCompleted());
    notifyListeners();
    _pump();
    return task;
  }

  /// web 专用：不建任务、不入队、不持久化，算好文件名后直接把链接交给浏览器。
  Future<Result<String>> downloadToBrowser(
    MediaPart part, {
    int? videoQuality,
    bool coverOnly = false,
  }) {
    final MediaStream? stream = part.pickVideoQuality(videoQuality);
    final String stem = buildVideoStem(
      title: source?.title ?? part.title,
      author: source?.author,
      publishedAt: source?.publishDate,
      contentId: contentIdOf(part.id),
      resolution: coverOnly ? null : stream?.displayLabel,
      fps: stream?.fps,
    );
    return _api.download(
      part,
      videoQuality: videoQuality,
      coverOnly: coverOnly,
      coverUrl: source?.coverUrl,
      fileStem: stem,
    );
  }

  /// 保存图文/图集：直接落盘，完成后写入一条已完成记录。
  Future<Result<String>> saveImages(
    ParsedSource source, {
    int? onlyIndex,
    bool separateLive = false,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final String downloadId = 'img_${_nextId()}';
    final int? index = onlyIndex == null || source.images.isEmpty
        ? null
        : onlyIndex.clamp(0, source.images.length - 1);
    final String stem = buildAlbumStem(
      title: source.title,
      author: source.author,
      publishedAt: source.publishDate,
      contentId: contentIdOf(
        source.sourceUrl ??
            (source.parts.isNotEmpty ? source.parts.first.id : null),
      ),
    );
    int savedCount = 0;
    int liveCount = 0;
    List<String> savedNames = const <String>[];
    final Result<String> result = await _api.saveImages(
      source.images,
      onlyIndex: index,
      downloadId: downloadId,
      fileStem: stem,
      separateLive: separateLive,
      onProgress: onProgress,
      onSaved: (int saved, int live) {
        savedCount = saved;
        liveCount = live;
      },
      onSavedFiles: (List<SavedMediaFile> files) {
        savedNames = <String>[
          ...savedNames,
          ...files.map((SavedMediaFile file) => file.name),
        ];
      },
    );
    if (result is Ok<String>) {
      final List<MediaImage> saved = index == null
          ? source.images
          : <MediaImage>[source.images[index]];
      final int total = savedCount > 0 ? savedCount : saved.length;
      final DownloadTask task = DownloadTask(
        id: downloadId,
        title: source.title,
        platform: source.platformLabel,
        qualityLabel: separateLive
            ? '图文 · $total 项'
            : '图文 · $total 张${liveCount > 0 ? ' · $liveCount 实况' : ''}',
        createdAt: DateTime.now(),
        status: DownloadStatus.completed,
        progress: 1,
        coverUrl: saved.isNotEmpty ? saved.first.primaryUrl : source.coverUrl,
        sourceUrl: source.sourceUrl,
        savedMessage: result.value,
        fileStem: stem,
        savedNames: savedNames,
      );
      _tasks.insert(0, task);
      notifyListeners();
      unawaited(_persistCompleted());
    }
    return result;
  }

  /// 手动合成实况照片（本地图片 + 视频）。
  Future<Result<String>> composeMotionPhoto({
    required String imagePath,
    required String videoPath,
  }) => _api.composeMotionPhoto(imagePath: imagePath, videoPath: videoPath);

  /// 把本地图片和视频分别保存。
  Future<Result<String>> saveLocalPair({
    required String imagePath,
    required String videoPath,
  }) => _api.saveLocalPair(imagePath: imagePath, videoPath: videoPath);

  /// 打开/分享已完成记录里的文件。
  Future<Result<String>> openTask(DownloadTask task) =>
      _api.openSaved(task.savedNames);

  Future<Result<String>> shareTask(DownloadTask task) =>
      _api.shareSaved(task.savedNames);

  Future<int> cacheBytes() => _api.cacheBytes();

  /// 清理临时缓存；有未完成任务时拒绝，避免清掉可续传的分片。
  Future<Result<String>> clearCache() async {
    final bool busy = _tasks.any(
      (DownloadTask t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.paused,
    );
    if (busy) {
      return const Err(AppError('有未完成的下载任务，请先完成或删除后再清理'));
    }
    final int freed = await _api.clearCache();
    return Ok('已清理 ${formatBytes(freed)}');
  }

  /// 启动前检查空间：优先用流自带大小，缺省时探测一次总长度。
  Future<String?> _checkDiskSpace(DownloadTask task) async {
    final MediaPart? part = task.part;
    if (part == null || task.coverOnly) {
      return null;
    }
    int? need;
    final MediaStream? video = part.pickVideoQuality(task.videoQuality);
    final int? videoBytes = video?.sizeBytes;
    if (videoBytes != null) {
      need = videoBytes + (part.pickAudio()?.sizeBytes ?? 0);
    }
    need ??= await _api.probeSelectionTotal(
      part,
      videoQuality: task.videoQuality,
    );
    if (need == null || need <= 0) {
      return null;
    }
    final int? free = await _api.freeBytes();
    if (free == null) {
      return null;
    }
    // 视频/音频需要“源分片 + 成品”两份空间；封面只有一份。
    // 续传时只算剩余字节，避免“空间明明够却提示不足”。
    final int remaining = (need - task.receivedBytes).clamp(0, need);
    final double factor = task.coverOnly ? 1.15 : 2.05;
    final int required = (remaining * factor).round() + 100 * 1024 * 1024;
    if (free >= required) {
      return null;
    }
    return '存储空间不足：需要约 ${formatBytes(required)}，可用 ${formatBytes(free)}';
  }

  /// 把排队中的任务按并发上限拉起来；先入先出。
  void _pump() {
    final int limit = (maxConcurrentProvider?.call() ?? 2).clamp(1, 4);
    int active = _tasks
        .where((DownloadTask t) => t.status == DownloadStatus.downloading)
        .length;
    if (active >= limit) {
      return;
    }
    for (final DownloadTask task in _tasks.reversed.toList(growable: false)) {
      if (active >= limit) {
        break;
      }
      if (task.status != DownloadStatus.queued ||
          _running.containsKey(task.id)) {
        continue;
      }
      active++;
      _startRun(task);
    }
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
    MediaPart? part = task.part;
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

    // 重启/历史记录里的任务没有签名流：真正开始时才重新拉一次。
    if (part.streams.isEmpty) {
      final Result<List<MediaStream>> refreshed = await _api.refreshStreams(
        part,
      );
      if (!_tasks.contains(task) || task.status != DownloadStatus.downloading) {
        return;
      }
      if (refreshed is Ok<List<MediaStream>> && refreshed.value.isNotEmpty) {
        part = MediaPart(
          id: part.id,
          title: part.title,
          durationSeconds: part.durationSeconds,
          streams: refreshed.value,
        );
        task.part = part;
      } else {
        task.status = DownloadStatus.failed;
        task.error = '获取该作品的下载地址失败';
        _maybeScheduleAutoRetry(task, task.error!);
        unawaited(_persistCompleted());
        notifyListeners();
        _pump();
        return;
      }
    }

    final String? spaceError = await _checkDiskSpace(task);
    if (spaceError != null) {
      if (!_tasks.contains(task) || task.status != DownloadStatus.downloading) {
        return;
      }
      task.status = DownloadStatus.failed;
      task.error = spaceError;
      unawaited(_persistCompleted());
      notifyListeners();
      _pump();
      return;
    }

    // 同一次运行内进度只增不减：音频流稍晚注册时总字节会变大，避免进度条回退。
    double runProgress = task.progress;
    final Result<String> result = await _api.download(
      part,
      videoQuality: task.videoQuality,
      coverOnly: task.coverOnly,
      saveCover: task.saveCover,
      coverUrl: task.coverUrl,
      downloadId: task.id,
      fileStem: task.fileStem,
      cancelToken: token,
      onSavedFiles: (List<SavedMediaFile> files) {
        task.savedNames = files
            .map((SavedMediaFile file) => file.name)
            .toList(growable: false);
      },
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
    // 成品已经落盘时，即使暂停信号在保存阶段才到，也必须按完成处理；
    // 否则用户会看到“已暂停”，继续后又生成第二份文件。
    if (result is Ok<String>) {
      _retryTimers.remove(task.id)?.cancel();
      _autoRetries.remove(task.id);
      _lastCompletedTask = task;
      task.status = DownloadStatus.completed;
      task.progress = 1;
      task.phase = null;
      task.savedMessage = result.value;
      final String? thumb = await _api.cacheCover(task.coverUrl, task.id);
      if (_tasks.contains(task)) {
        task.thumbnailPath = thumb;
      }
      unawaited(_persistCompleted());
      notifyListeners();
      _pump();
      return;
    }
    if (task.status == DownloadStatus.paused) {
      notifyListeners();
      _pump();
      return;
    }
    if (result is Err<String>) {
      task.phase = null;
      task.status = DownloadStatus.failed;
      task.error = result.error.message;
      _maybeScheduleAutoRetry(task, result.error.message);
    }
    unawaited(_persistCompleted());
    notifyListeners();
    _pump();
  }

  /// 网络类失败自动重试两次（2s / 5s），每次重试都会刷新签名地址后继续续传。
  /// 权限、空间不足、地址无效等确定性错误不重试。
  void _maybeScheduleAutoRetry(DownloadTask task, String message) {
    if (!_shouldAutoRetry(message)) {
      return;
    }
    final int attempt = (_autoRetries[task.id] ?? 0) + 1;
    if (attempt > 2) {
      return;
    }
    _autoRetries[task.id] = attempt;
    final int seconds = attempt == 1 ? 2 : 5;
    task.phase = '网络异常，$seconds 秒后自动重试（$attempt/2）';
    _retryTimers[task.id]?.cancel();
    _retryTimers[task.id] = Timer(Duration(seconds: seconds), () {
      _retryTimers.remove(task.id);
      if (!_tasks.contains(task) || task.status != DownloadStatus.failed) {
        return;
      }
      task.phase = null;
      unawaited(retryTask(task, automatic: true));
    });
  }

  bool _shouldAutoRetry(String message) {
    const List<String> permanent = <String>[
      '已暂停',
      '存储空间不足',
      '没有相册',
      '权限',
      '没有可下载',
      '无法识别',
      '不是有效',
      '地址返回',
    ];
    for (final String word in permanent) {
      if (message.contains(word)) {
        return false;
      }
    }
    return true;
  }

  /// 网络恢复后重试因网络失败的记录（用户主动暂停的不动）。
  void _onNetworkChanged(bool online) {
    if (!online) {
      return;
    }
    final DateTime now = DateTime.now();
    if (now.difference(_lastNetworkRetryAt) < const Duration(seconds: 8)) {
      return;
    }
    _lastNetworkRetryAt = now;
    for (final DownloadTask task in _tasks.toList(growable: false)) {
      if (task.status == DownloadStatus.failed && _isNetworkError(task.error)) {
        unawaited(retryTask(task));
      }
    }
  }

  bool _isNetworkError(String? error) {
    final String text = (error ?? '').toLowerCase();
    if (text.isEmpty) {
      return false;
    }
    return text.contains('网络') ||
        text.contains('connection') ||
        text.contains('timeout') ||
        text.contains('超时') ||
        text.contains('http 403') ||
        text.contains('http 5');
  }

  void pauseTask(DownloadTask task) {
    _retryTimers.remove(task.id)?.cancel();
    _autoRetries.remove(task.id);
    if (task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      unawaited(_persistCompleted());
      notifyListeners();
      return;
    }
    if (task.status != DownloadStatus.downloading) {
      return;
    }
    task.status = DownloadStatus.paused;
    _tokens[task.id]?.cancel('paused');
    unawaited(_persistCompleted());
    notifyListeners();
  }

  /// 继续暂停/失败的任务。先等上一次运行彻底结束（Dio 取消是异步的），
  /// 再进入队列，由并发调度器决定何时真正开始。
  Future<void> resumeTask(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued ||
        task.part == null) {
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
    task.status = DownloadStatus.queued;
    task.error = null;
    notifyListeners();
    _pump();
  }

  /// 重试失败任务：先用最新地址刷新流（解决签名 URL 过期 403），再继续下载。
  Future<void> retryTask(DownloadTask task, {bool automatic = false}) async {
    if (_running.containsKey(task.id) || _retrying.contains(task.id)) {
      return;
    }
    if (!automatic) {
      _retryTimers.remove(task.id)?.cancel();
      _autoRetries.remove(task.id);
    }
    _retrying.add(task.id);
    try {
      final MediaPart? oldPart = task.part;
      final MediaPart? part = oldPart;
      if (part != null) {
        final Result<List<MediaStream>> refreshed = await _api.refreshStreams(
          part,
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
      // 同一画质/音轨才可复用临时分片；档位变了必须清掉，避免拼出坏文件。
      bool resumable =
          oldPart != null &&
          oldPart.streams.isNotEmpty &&
          task.part != null &&
          oldPart.sameDownloadSelection(
            task.part!,
            videoQuality: task.videoQuality,
          );
      // 流身份相同还不够：旧任务已知总长度时，再探测一次新流总长度。
      if (resumable &&
          !task.coverOnly &&
          task.part != null &&
          task.totalBytes > 0) {
        final int? newTotal = await _api.probeSelectionTotal(
          task.part!,
          videoQuality: task.videoQuality,
        );
        if (newTotal == null || newTotal != task.totalBytes) {
          resumable = false;
        }
      }
      if (!resumable) {
        await _api.cleanup(task.id);
        task.progress = 0;
      }
      await resumeTask(task);
    } finally {
      _retrying.remove(task.id);
    }
  }

  void removeTask(DownloadTask task) {
    _retryTimers.remove(task.id)?.cancel();
    _autoRetries.remove(task.id);
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
    _pump();
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
    // web 上不落盘，历史记录里的文件点不开，干脆不恢复。
    if (kIsWeb) {
      return;
    }
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
          final Map<String, dynamic> record = (item as Map)
              .cast<String, dynamic>();
          // 只保留抖音记录；非抖音记录直接跳过。
          final String platform = (record['platform'] ?? '').toString();
          final String sourceUrl = (record['sourceUrl'] ?? '').toString();
          final bool isDouyin =
              platform.contains('抖音') ||
              platform.toLowerCase().contains('douyin') ||
              sourceUrl.toLowerCase().contains('douyin');
          if ((platform.isNotEmpty || sourceUrl.isNotEmpty) && !isDouyin) {
            continue;
          }
          // 「仅音频」已移除，历史里这类任务不再加载。
          if (record['audioOnly'] == true) {
            continue;
          }
          final DownloadTask task = DownloadTask.fromRecord(record);
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

  @override
  void notifyListeners() {
    super.notifyListeners();
    _syncDownloadNotification();
  }

  /// 把下载状态同步到前台服务通知；进度最多 700ms 刷新一次。
  void _syncDownloadNotification() {
    final List<DownloadTask> active = _tasks
        .where((DownloadTask t) => t.status == DownloadStatus.downloading)
        .toList(growable: false);
    if (active.isNotEmpty) {
      _hadActiveTask = true;
      _lastCompletedTask = null;
      final int received = active.fold<int>(
        0,
        (int sum, DownloadTask t) => sum + t.receivedBytes,
      );
      final int total = active.fold<int>(
        0,
        (int sum, DownloadTask t) => sum + t.totalBytes,
      );
      final bool indeterminate = total <= 0;
      final int progress = total > 0
          ? ((received / total) * 100).round().clamp(0, 100)
          : 0;
      final String title = active.length == 1
          ? active.first.title
          : '正在下载 ${active.length} 个任务';
      final String text = indeterminate
          ? (active.length == 1 ? '正在准备…' : '${active.length} 个任务排队下载中')
          : '$progress% · ${active.length} 个任务';
      final DateTime now = DateTime.now();
      if (!_serviceRunning) {
        _serviceRunning = true;
        _lastServiceUpdate = now;
        unawaited(DownloadNotifications.ensurePermission());
        unawaited(
          DownloadNotifications.start(
            title: title,
            text: text,
            progress: progress,
            indeterminate: indeterminate,
          ),
        );
      } else if (now.difference(_lastServiceUpdate) >=
          const Duration(milliseconds: 700)) {
        _lastServiceUpdate = now;
        unawaited(
          DownloadNotifications.update(
            title: title,
            text: text,
            progress: progress,
            indeterminate: indeterminate,
          ),
        );
      }
      return;
    }
    if (!_serviceRunning) {
      return;
    }
    _serviceRunning = false;
    final DownloadTask? done = _lastCompletedTask;
    if (_hadActiveTask && done != null && _tasks.contains(done)) {
      unawaited(
        DownloadNotifications.complete(
          title: '下载完成',
          text: done.savedMessage ?? done.title,
        ),
      );
    } else {
      unawaited(DownloadNotifications.stop());
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

/// 参数名 qualityLabel 会遮蔽同名顶层函数，单独包一层供批量任务使用。
String _qualityText(int qn) => qualityLabel(qn);
