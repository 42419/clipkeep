import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'result.dart';

/// 下载视频/音频流，支持按画质、仅音频、仅封面、视频+封面，并保存到相册/下载目录。
class MediaDownloader {
  MediaDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const MethodChannel _mediaStore = MethodChannel('clipkeep/media_store');

  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

  Future<Result<String>> download(
    MediaPart part, {
    int? videoQuality,
    bool audioOnly = false,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    try {
      final dir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch.toString();
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
        saveCover: saveCover,
        coverUrl: coverUrl,
        agg: agg,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } on GalException catch (e) {
      return Err(AppError('保存到相册失败', cause: e));
    } catch (e) {
      return Err(AppError('下载失败', cause: e));
    }
  }

  Future<Result<String>> _downloadVideo(
    MediaPart part,
    String dirPath,
    String stamp, {
    int? videoQuality,
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

    await _downloadStream(video, videoPath, agg, cancelToken, onProgress);
    agg.finishStream();
    if (hasAudio) {
      await _downloadStream(audio, audioPath, agg, cancelToken, onProgress);
      agg.finishStream();
    }
    onProgress?.call(agg.snapshot(fallback: 0.9));

    final command = hasAudio
        ? '-y -i "$videoPath" -i "$audioPath" -c copy -map 0:v:0 -map 1:a:0 "$outputPath"'
        : '-y -i "$videoPath" -c copy "$outputPath"';
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getOutput();
      await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
      return Err(AppError('音视频合并失败', cause: logs));
    }

    if (!await _ensureGalleryAccess()) {
      await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
      return const Err(AppError('没有相册写入权限'));
    }
    await Gal.putVideo(outputPath, album: AppConstants.albumName);

    bool coverSaved = false;
    if (saveCover) {
      coverSaved = await _saveCover(coverUrl, dirPath, stamp);
    }
    final int outLen = await File(outputPath).length();
    onProgress?.call(
      DownloadProgress(fraction: 1, receivedBytes: outLen, totalBytes: outLen),
    );
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
      return const Err(AppError('没有可下载的音频流'));
    }
    final tempPath = '$dirPath/clipkeep_a_$stamp.m4s';
    await _downloadStream(audio, tempPath, agg, cancelToken, onProgress);
    agg.finishStream();

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
          headers: _imageHeaders,
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (int received, int total) {
          agg.update(received, total);
          onProgress?.call(agg.snapshot());
        },
      );
      agg.finishStream();
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

  Future<bool> _saveCover(String? coverUrl, String dirPath, String stamp) async {
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
          headers: _imageHeaders,
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

  Future<void> _downloadStream(
    MediaStream stream,
    String destination,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
  ) async {
    await _dio.download(
      stream.primaryUrl,
      destination,
      cancelToken: cancelToken,
      options: Options(
        headers: stream.headers,
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 30),
      ),
      onReceiveProgress: (int received, int total) {
        agg.update(received, total);
        onProgress?.call(agg.snapshot());
      },
    );
  }
}

/// 汇总多个流（视频+音频）的字节进度。
class _ByteAggregator {
  int _finished = 0;
  int _curReceived = 0;
  int _curTotal = 0;
  final DateTime _start = DateTime.now();

  void update(int received, int total) {
    _curReceived = received;
    if (total > 0) {
      _curTotal = total;
    }
  }

  void finishStream() {
    _finished += _curTotal > 0 ? _curTotal : _curReceived;
    _curReceived = 0;
    _curTotal = 0;
  }

  DownloadProgress snapshot({double? fallback}) {
    final int received = _finished + _curReceived;
    final int total = _finished + _curTotal;
    final double elapsed =
        DateTime.now().difference(_start).inMilliseconds / 1000.0;
    final double speed = elapsed > 0 ? received / elapsed : 0;
    double fraction;
    if (total > 0) {
      fraction = received / total;
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
