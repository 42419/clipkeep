import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'result.dart';

/// 下载视频/音频流，支持按画质、仅音频、仅封面、视频+封面，并保存到相册/下载目录。
class MediaDownloader {
  MediaDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const MethodChannel _mediaStore = MethodChannel(
    'clipkeep/media_store',
  );

  String? _cookie;

  Map<String, String> _withCookie(Map<String, String> base) {
    final String? cookie = _cookie;
    if (cookie == null || cookie.isEmpty) {
      return base;
    }
    return <String, String>{...base, 'cookie': cookie};
  }

  /// 把异常转成简短可读文案，便于在下载失败卡片上定位问题。
  String _describe(Object e) {
    if (e is DioException) {
      final int? code = e.response?.statusCode;
      return 'HTTP ${code ?? '-'} ${e.type.name}';
    }
    final String s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

  Future<Result<String>> download(
    MediaPart part, {
    int? videoQuality,
    bool audioOnly = false,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    String? cookie,
    String? downloadId,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    _cookie = cookie;
    bool saveToGallery = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      saveToGallery = prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
    } catch (_) {
      // 读取失败默认保存到相册。
    }
    try {
      final dir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      // downloadId 稳定（= task.id），使暂停/重试能命中同一批临时文件，实现断点续传。
      final stamp =
          downloadId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final agg = _ByteAggregator();
      if (coverOnly) {
        return await _downloadCoverOnly(
          coverUrl,
          dir.path,
          stamp,
          agg,
          cancelToken,
          onProgress,
        );
      }
      if (audioOnly) {
        return await _downloadAudioOnly(
          part,
          dir.path,
          stamp,
          agg,
          cancelToken,
          onProgress,
        );
      }
      return await _downloadVideo(
        part,
        dir.path,
        stamp,
        videoQuality: videoQuality,
        saveToGallery: saveToGallery,
        saveCover: saveCover,
        coverUrl: coverUrl,
        agg: agg,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } on GalException catch (e) {
      return Err(AppError('保存到相册失败', cause: e));
    } catch (e) {
      return Err(AppError('下载失败：${_describe(e)}', cause: e));
    }
  }

  Future<Result<String>> _downloadVideo(
    MediaPart part,
    String dirPath,
    String stamp, {
    int? videoQuality,
    required bool saveToGallery,
    required bool saveCover,
    String? coverUrl,
    required _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final video = part.pickVideoQuality(videoQuality);
    if (video == null || video.primaryUrl.isEmpty) {
      return const Err(AppError('该视频没有可下载的视频流'));
    }
    final audio = part.pickAudio();
    final hasAudio = audio != null && audio.primaryUrl.isNotEmpty;
    final videoPath = '$dirPath/clipkeep_v_$stamp.m4s';
    final audioPath = '$dirPath/clipkeep_a_$stamp.m4s';
    final outputPath = '$dirPath/clipkeep_$stamp.mp4';

    // 下载阶段占 0~90%，合并阶段占 90~100%。
    agg.scale = 0.9;

    await Future.wait(<Future<void>>[
      _downloadStream(video, videoPath, agg, 'video', cancelToken, onProgress),
      if (hasAudio)
        _downloadStream(
          audio,
          audioPath,
          agg,
          'audio',
          cancelToken,
          onProgress,
        ),
    ]);
    agg.finishStreamKey('video');
    if (hasAudio) {
      agg.finishStreamKey('audio');
    }
    final DownloadProgress beforeMerge = agg.snapshot();
    onProgress?.call(
      DownloadProgress(
        fraction: 0.9,
        receivedBytes: beforeMerge.receivedBytes,
        totalBytes: beforeMerge.totalBytes,
        phase: '正在合并音视频…',
      ),
    );

    final command = hasAudio
        ? '-y -i "$videoPath" -i "$audioPath" -c copy -map 0:v:0 -map 1:a:0 "$outputPath"'
        : '-y -i "$videoPath" -c copy "$outputPath"';
    final Completer<ReturnCode?> merge = Completer<ReturnCode?>();
    final int totalMs = ((part.durationSeconds ?? 0) * 1000).round();
    final FFmpegSession session;
    try {
      session = await FFmpegKit.executeAsync(
        command,
        (FFmpegSession session) async {
          final ReturnCode? code = await session.getReturnCode();
          if (!merge.isCompleted) {
            merge.complete(code);
          }
        },
        null,
        (Statistics stats) {
          if (totalMs <= 0 || merge.isCompleted) {
            return;
          }
          final double ratio = (stats.getTime() / totalMs).clamp(0.0, 1.0);
          final DownloadProgress base = agg.snapshot();
          onProgress?.call(
            DownloadProgress(
              fraction: 0.9 + 0.1 * ratio,
              receivedBytes: base.receivedBytes,
              totalBytes: base.totalBytes,
              phase: '正在合并音视频…',
            ),
          );
        },
      );
    } catch (e) {
      await _cleanupQuietly(<String>[outputPath]);
      return Err(AppError('调用 FFmpeg 失败：${_describe(e)}', cause: e));
    }
    final ReturnCode? returnCode = await merge.future;
    if (!ReturnCode.isSuccess(returnCode)) {
      final String? logs = await session.getOutput();
      await _cleanupQuietly(<String>[outputPath]);
      return Err(AppError('音视频合并失败', cause: logs));
    }

    final int outLen = await File(outputPath).length();
    onProgress?.call(
      DownloadProgress(fraction: 1, receivedBytes: outLen, totalBytes: outLen),
    );

    if (!saveToGallery) {
      final Directory outDir = Directory('$dirPath/ClipKeep');
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final String finalPath = '${outDir.path}/ClipKeep_$stamp.mp4';
      await _moveFile(outputPath, finalPath);
      await _cleanupQuietly(<String>[videoPath, audioPath]);
      return Ok('已保存到 下载/ClipKeep：$finalPath');
    }

    if (!await _ensureGalleryAccess()) {
      await _cleanupQuietly(<String>[outputPath]);
      return const Err(AppError('没有相册写入权限'));
    }
    await Gal.putVideo(outputPath, album: AppConstants.albumName);

    bool coverSaved = false;
    if (saveCover) {
      coverSaved = await _saveCover(coverUrl, dirPath, stamp);
    }
    await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
    return Ok(coverSaved ? '已保存视频与封面（ClipKeep）' : '已保存到相册（ClipKeep）');
  }

  Future<Result<String>> _downloadAudioOnly(
    MediaPart part,
    String dirPath,
    String stamp,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    final audio = part.pickAudio();
    if (audio == null || audio.primaryUrl.isEmpty) {
      // 抖音等单文件 mp4 没有独立音频流：下载视频后抽取音轨。
      return _extractAudioFromVideo(
        part,
        dirPath,
        stamp,
        agg,
        cancelToken,
        onProgress,
      );
    }
    final tempPath = '$dirPath/clipkeep_a_$stamp.m4s';
    await _downloadStream(
      audio,
      tempPath,
      agg,
      'audio',
      cancelToken,
      onProgress,
    );
    agg.finishStreamKey('audio');

    final String displayName = 'ClipKeep_audio_$stamp.m4a';
    String? savedPath;
    try {
      savedPath = await _mediaStore.invokeMethod<String>(
        'saveAudio',
        <String, String>{'path': tempPath, 'displayName': displayName},
      );
    } catch (_) {
      savedPath = null;
    }

    final int audioLen = await File(tempPath).length();
    onProgress?.call(
      DownloadProgress(
        fraction: 1,
        receivedBytes: audioLen,
        totalBytes: audioLen,
      ),
    );

    if (savedPath != null) {
      await _cleanupQuietly(<String>[tempPath]);
      return Ok('已保存音频到 下载/ClipKeep：$displayName');
    }

    final outDir = Directory('$dirPath/ClipKeep');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final fallbackPath = '${outDir.path}/$displayName';
    try {
      await File(tempPath).rename(fallbackPath);
    } catch (_) {
      await File(tempPath).copy(fallbackPath);
      await _cleanupQuietly(<String>[tempPath]);
    }
    return Ok('已保存音频：$fallbackPath');
  }

  /// 无独立音频流时（如抖音单文件 mp4）：下载视频后用 FFmpeg 抽取音轨。
  Future<Result<String>> _extractAudioFromVideo(
    MediaPart part,
    String dirPath,
    String stamp,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    final MediaStream? video = part.pickVideoQuality(null);
    if (video == null || video.primaryUrl.isEmpty) {
      return const Err(AppError('没有可下载的音频流'));
    }
    final String tempVideo = '$dirPath/clipkeep_av_$stamp.m4s';
    await _downloadStream(
      video,
      tempVideo,
      agg,
      'video',
      cancelToken,
      onProgress,
    );
    agg.finishStreamKey('video');

    final String outPath = '$dirPath/clipkeep_audio_$stamp.m4a';
    FFmpegSession session = await FFmpegKit.execute(
      '-y -i "$tempVideo" -vn -c:a copy "$outPath"',
    );
    ReturnCode? code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      session = await FFmpegKit.execute(
        '-y -i "$tempVideo" -vn -c:a aac -b:a 192k "$outPath"',
      );
      code = await session.getReturnCode();
    }
    if (!ReturnCode.isSuccess(code)) {
      await _cleanupQuietly(<String>[tempVideo, outPath]);
      return const Err(AppError('提取音频失败'));
    }
    await _cleanupQuietly(<String>[tempVideo]);

    final String displayName = 'ClipKeep_audio_$stamp.m4a';
    String? savedPath;
    try {
      savedPath = await _mediaStore.invokeMethod<String>(
        'saveAudio',
        <String, String>{'path': outPath, 'displayName': displayName},
      );
    } catch (_) {
      savedPath = null;
    }
    final int audioLen = await File(outPath).length();
    onProgress?.call(
      DownloadProgress(
        fraction: 1,
        receivedBytes: audioLen,
        totalBytes: audioLen,
      ),
    );
    if (savedPath != null) {
      await _cleanupQuietly(<String>[outPath]);
      return Ok('已保存音频到 下载/ClipKeep：$displayName');
    }
    final Directory outDir = Directory('$dirPath/ClipKeep');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final String fallbackPath = '${outDir.path}/$displayName';
    try {
      await File(outPath).rename(fallbackPath);
    } catch (_) {
      await File(outPath).copy(fallbackPath);
      await _cleanupQuietly(<String>[outPath]);
    }
    return Ok('已保存音频：$fallbackPath');
  }

  Future<Result<String>> _downloadCoverOnly(
    String? coverUrl,
    String dirPath,
    String stamp,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return const Err(AppError('没有可保存的封面'));
    }
    if (!await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }
    try {
      final coverPath = '$dirPath/clipkeep_cover_$stamp.jpg';
      await _dio.download(
        url,
        coverPath,
        cancelToken: cancelToken,
        options: Options(
          headers: _withCookie(_imageHeaders),
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (int received, int total) {
          agg.updateStream('cover', received, total);
          onProgress?.call(agg.snapshot());
        },
      );
      agg.finishStreamKey('cover');
      await Gal.putImage(coverPath, album: AppConstants.albumName);
      final int coverLen = await File(coverPath).length();
      onProgress?.call(
        DownloadProgress(
          fraction: 1,
          receivedBytes: coverLen,
          totalBytes: coverLen,
        ),
      );
      await _cleanupQuietly(<String>[coverPath]);
      return Ok('封面已保存到相册（ClipKeep）');
    } on GalException {
      return const Err(AppError('保存到相册失败'));
    } catch (e) {
      return Err(AppError('保存封面失败', cause: e));
    }
  }

  Future<bool> _saveCover(
    String? coverUrl,
    String dirPath,
    String stamp,
  ) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return false;
    }
    try {
      if (!await _ensureGalleryAccess()) {
        return false;
      }
      final coverPath = '$dirPath/clipkeep_cover_$stamp.jpg';
      await _dio.download(
        url,
        coverPath,
        options: Options(
          headers: _withCookie(_imageHeaders),
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      await Gal.putImage(coverPath, album: AppConstants.albumName);
      await _cleanupQuietly(<String>[coverPath]);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureGalleryAccess() async {
    if (await Gal.hasAccess(toAlbum: true)) {
      return true;
    }
    return Gal.requestAccess(toAlbum: true);
  }

  String? _normalizeUrl(String? raw) {
    if (raw == null) {
      return null;
    }
    final String v = raw.trim();
    if (v.isEmpty) {
      return null;
    }
    if (v.startsWith('//')) {
      return 'https:$v';
    }
    if (v.startsWith('http://')) {
      return 'https://${v.substring(7)}';
    }
    if (v.startsWith('https://')) {
      return v;
    }
    return 'https://$v';
  }

  Future<void> _cleanupQuietly(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // 清理失败不影响主流程。
      }
    }
  }

  Future<void> _moveFile(String from, String to) async {
    final File target = File(to);
    if (await target.exists()) {
      await target.delete();
    }
    try {
      await File(from).rename(to);
    } catch (_) {
      await File(from).copy(to);
      await _cleanupQuietly(<String>[from]);
    }
  }

  /// 依次尝试主地址与备用地址；分片/单连接均支持断点续传。
  Future<void> _downloadStream(
    MediaStream stream,
    String destination,
    _ByteAggregator agg,
    String key,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    final List<String> candidates = <String>[
      if (stream.primaryUrl.isNotEmpty) stream.primaryUrl,
      ...stream.urls.where(
        (String u) => u.isNotEmpty && u != stream.primaryUrl,
      ),
    ];
    if (candidates.isEmpty) {
      throw Exception('没有可用的下载地址');
    }
    Object? lastError;
    for (final String url in candidates) {
      try {
        await _downloadStreamFrom(
          url,
          stream,
          destination,
          agg,
          key,
          cancelToken,
          onProgress,
        );
        return;
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) {
          rethrow;
        }
        lastError = e;
      }
    }
    throw lastError ?? Exception('全部下载地址均失败');
  }

  Future<void> _downloadStreamFrom(
    String url,
    MediaStream stream,
    String destination,
    _ByteAggregator agg,
    String key,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    const int threshold = 4 * 1024 * 1024;
    final ({bool supported, int? total}) probe = await _probeRange(
      url,
      stream.headers,
      cancelToken,
    );
    final int? total = probe.total;

    // 已完成（例如另一个流失败后重试）直接跳过，避免重复下载。
    final int destExisting = await _existingLength(destination);
    if (total != null && destExisting >= total) {
      agg.beginStream(key, total);
      agg.updateStream(key, total, total);
      onProgress?.call(agg.snapshot());
      return;
    }

    if (probe.supported && total != null && total > threshold) {
      try {
        await _downloadMultiPart(
          url,
          stream,
          destination,
          total,
          agg,
          key,
          cancelToken,
          onProgress,
        );
        return;
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) {
          rethrow;
        }
        // 分片失败：清掉分片后回退单连接（同一地址）。
        await _cleanupQuietly(<String>[
          for (int i = 0; i < 64; i++) '$destination.part$i',
        ]);
      }
    }

    final int existing = await _existingLength(destination);
    agg.beginStream(key, total ?? 0);
    if (existing > 0) {
      agg.updateStream(key, existing, total ?? 0);
      onProgress?.call(agg.snapshot());
    }
    final int? to = probe.supported ? (total != null ? total - 1 : null) : null;
    await _downloadRangeAppend(
      url,
      stream.headers,
      destination,
      existing,
      to,
      cancelToken,
      (int received) {
        agg.updateStream(key, received, total ?? 0);
        onProgress?.call(agg.snapshot());
      },
    );
  }

  Future<void> _downloadMultiPart(
    String url,
    MediaStream stream,
    String destination,
    int total,
    _ByteAggregator agg,
    String key,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    final int parts = total > 80 * 1024 * 1024
        ? 6
        : (total > 20 * 1024 * 1024 ? 4 : 2);
    final int chunk = (total / parts).ceil();
    final List<String> partPaths = <String>[];
    final List<int> expectedLens = <int>[];
    final List<int> startOffsets = <int>[];
    final List<int> haveLens = <int>[];
    for (int i = 0; i < parts; i++) {
      final int start = i * chunk;
      if (start > total - 1) {
        break;
      }
      final int end = (i == parts - 1) ? total - 1 : (start + chunk - 1);
      final String partPath = '$destination.part$i';
      final int expected = end - start + 1;
      int have = await _existingLength(partPath);
      if (have > expected) {
        await _cleanupQuietly(<String>[partPath]);
        have = 0;
      }
      partPaths.add(partPath);
      expectedLens.add(expected);
      startOffsets.add(start);
      haveLens.add(have);
    }
    int known = 0;
    for (final int h in haveLens) {
      known += h;
    }
    agg.beginStream(key, total);
    agg.updateStream(key, known, total);
    onProgress?.call(agg.snapshot());

    final List<int> receivedPerPart = List<int>.from(haveLens);
    final List<Future<void>> futures = <Future<void>>[];
    for (int i = 0; i < partPaths.length; i++) {
      final int expected = expectedLens[i];
      final int have = haveLens[i];
      if (have >= expected) {
        continue;
      }
      final int from = startOffsets[i] + have;
      final int to = startOffsets[i] + expected - 1;
      futures.add(
        _downloadRangeAppend(
          url,
          stream.headers,
          partPaths[i],
          have,
          to,
          cancelToken,
          (int received) {
            receivedPerPart[i] = received;
            int sum = 0;
            for (final int v in receivedPerPart) {
              sum += v;
            }
            agg.updateStream(key, sum, total);
            onProgress?.call(agg.snapshot());
          },
          rangeFrom: from,
        ),
      );
    }
    await Future.wait(futures);

    for (int i = 0; i < partPaths.length; i++) {
      final int len = await _existingLength(partPaths[i]);
      if (len != expectedLens[i]) {
        throw Exception('分片下载不完整');
      }
    }
    final IOSink sink = File(destination).openWrite();
    for (final String partPath in partPaths) {
      await sink.addStream(File(partPath).openRead());
    }
    await sink.close();
    await _cleanupQuietly(partPaths);
    agg.updateStream(key, total, total);
    onProgress?.call(agg.snapshot());
  }

  Future<int> _existingLength(String path) async {
    try {
      final File f = File(path);
      if (await f.exists()) {
        return await f.length();
      }
    } catch (_) {
      // ignore
    }
    return 0;
  }

  /// 从 existing（该文件已下载字节）继续下载到 to；服务端忽略 Range 时整段重下。
  Future<void> _downloadRangeAppend(
    String url,
    Map<String, String> headers,
    String path,
    int existing,
    int? to,
    CancelToken? cancelToken,
    void Function(int received) onProgress, {
    int? rangeFrom,
  }) async {
    final int from = rangeFrom ?? existing;
    final Map<String, String> requestHeaders = <String, String>{
      ..._withCookie(headers),
      if (to != null)
        'Range': 'bytes=$from-$to'
      else if (from > 0)
        'Range': 'bytes=$from-',
    };
    final Response<ResponseBody> res = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: requestHeaders,
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 30),
        validateStatus: (int? s) => s != null && (s == 200 || s == 206),
      ),
    );
    final bool honorsRange = res.statusCode == 206;
    if (rangeFrom != null && !honorsRange) {
      throw Exception('服务端不支持分段');
    }
    final bool append = existing > 0 && honorsRange;
    final IOSink sink = File(path)
        .openWrite(mode: append ? FileMode.append : FileMode.write);
    int received = append ? existing : 0;
    try {
      await for (final List<int> chunk in res.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<({bool supported, int? total})> _probeRange(
    String url,
    Map<String, String> headers,
    CancelToken? cancelToken,
  ) async {
    try {
      final Response<List<int>> res = await _dio.get<List<int>>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, String>{
            ..._withCookie(headers),
            'Range': 'bytes=0-1',
          },
          validateStatus: (int? status) => status != null && status < 500,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final String? contentRange = res.headers.value('content-range');
      if (res.statusCode == 206 && contentRange != null) {
        final String totalPart = contentRange.split('/').last;
        return (supported: true, total: int.tryParse(totalPart));
      }
      final int? length = int.tryParse(
        res.headers.value('content-length') ?? '',
      );
      return (
        supported: false,
        total: (length != null && length > 0) ? length : null,
      );
    } catch (_) {
      return (supported: false, total: null);
    }
  }
}

/// 汇总多个并发流（视频 + 音频）的字节进度。
class _ByteAggregator {
  double scale = 1.0;
  int _finished = 0;
  final Map<String, int> _recv = <String, int>{};
  final Map<String, int> _tot = <String, int>{};
  final DateTime _start = DateTime.now();

  void beginStream(String key, int total) {
    _recv[key] = 0;
    _tot[key] = total > 0 ? total : 0;
  }

  void updateStream(String key, int received, int total) {
    _recv[key] = received;
    if (total > 0) {
      _tot[key] = total;
    }
  }

  void finishStreamKey(String key) {
    final int total = _tot[key] ?? 0;
    final int received = _recv[key] ?? 0;
    _finished += total > 0 ? total : received;
    _recv.remove(key);
    _tot.remove(key);
  }

  DownloadProgress snapshot({double? fallback}) {
    int received = _finished;
    int total = _finished;
    for (final int value in _recv.values) {
      received += value;
    }
    for (final int value in _tot.values) {
      total += value;
    }
    final double elapsed =
        DateTime.now().difference(_start).inMilliseconds / 1000.0;
    final double speed = elapsed > 0 ? received / elapsed : 0;
    double fraction;
    if (total > 0) {
      fraction = (received / total) * scale;
    } else {
      fraction = fallback ?? 0;
    }
    return DownloadProgress(
      fraction: fraction.clamp(0.0, 1.0),
      receivedBytes: received,
      totalBytes: total,
      speedBytesPerSec: speed,
    );
  }
}
