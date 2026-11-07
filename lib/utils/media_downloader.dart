import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import 'image_headers.dart';

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

  Map<String, String> _withCookie(Map<String, String> base, {String? url}) {
    final String? cookie = _cookie;
    if (cookie == null || cookie.isEmpty || !_isBiliHost(url)) {
      return base;
    }
    return <String, String>{...base, 'cookie': cookie};
  }

  /// 只把 B 站 Cookie 发给 B 站域名，避免把登录凭据泄露给抖音等第三方 CDN。
  /// 必须按 host 的后缀匹配：`contains('bilibili.com')` 会把
  /// `bilibili.com.evil.example` 或带该字样的路径也算作 B 站。
  bool _isBiliHost(String? url) {
    final String host = (Uri.tryParse(url ?? '')?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      return false;
    }
    for (final String domain in _biliDomains) {
      if (host == domain || host.endsWith('.$domain')) {
        return true;
      }
    }
    return false;
  }

  static const List<String> _biliDomains = <String>[
    'bilibili.com',
    'bilivideo.com',
    'hdslb.com',
    'b23.tv',
    'bili2233.cn',
  ];

  /// 把异常转成简短可读文案，便于在下载失败卡片上定位问题。
  String _describe(Object e) {
    if (e is DioException) {
      final int? code = e.response?.statusCode;
      return 'HTTP ${code ?? '-'} ${e.type.name}';
    }
    final String s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

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
          saveToGallery: saveToGallery,
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
    // 暂停发生在下载收尾阶段：保留 m4s 供续传，直接交给上层按「已暂停」处理。
    if (cancelToken?.isCancelled ?? false) {
      return const Err(AppError('已暂停'));
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
    // 合并不可通过 Dio 取消，需显式终止 FFmpeg 会话，否则暂停后仍会写入相册。
    final CancelToken? token = cancelToken;
    if (token != null) {
      unawaited(
        token.whenCancel.then((_) => FFmpegKit.cancel(session.getSessionId())),
      );
    }
    final ReturnCode? returnCode = await merge.future;
    if (cancelToken?.isCancelled ?? false) {
      await _cleanupQuietly(<String>[outputPath]);
      return const Err(AppError('已暂停'));
    }
    if (!ReturnCode.isSuccess(returnCode)) {
      final String? logs = await session.getOutput();
      await _cleanupQuietly(<String>[outputPath]);
      return Err(AppError('音视频合并失败', cause: logs));
    }

    final int outLen = await File(outputPath).length();
    onProgress?.call(
      DownloadProgress(fraction: 1, receivedBytes: outLen, totalBytes: outLen),
    );

    if (cancelToken?.isCancelled ?? false) {
      await _cleanupQuietly(<String>[outputPath]);
      return const Err(AppError('已暂停'));
    }

    if (!saveToGallery) {
      final String? saved = await _saveToDownloads(
        outputPath,
        'ClipKeep_$stamp.mp4',
        'video/mp4',
      );
      if (saved == null) {
        await _cleanupQuietly(<String>[outputPath]);
        return const Err(AppError('保存到下载目录失败（可能缺少存储权限）'));
      }
      // 关闭相册时同样要处理「视频+封面」，否则选项静默失效。
      bool coverSaved = false;
      if (saveCover) {
        coverSaved = await _saveCover(
          coverUrl,
          dirPath,
          stamp,
          saveToGallery: false,
        );
      }
      await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
      return Ok(coverSaved ? '已保存视频与封面到 Download/ClipKeep' : '已保存到 $saved');
    }

    if (!await _ensureGalleryAccess()) {
      await _cleanupQuietly(<String>[outputPath]);
      return const Err(AppError('没有相册写入权限'));
    }
    try {
      await Gal.putVideo(outputPath, album: AppConstants.albumName);
    } catch (e) {
      await _cleanupQuietly(<String>[outputPath]);
      return Err(AppError('保存到相册失败：${_describe(e)}', cause: e));
    }

    bool coverSaved = false;
    if (saveCover) {
      coverSaved = await _saveCover(
        coverUrl,
        dirPath,
        stamp,
        saveToGallery: saveToGallery,
      );
    }
    await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
    return Ok(coverSaved ? '已保存视频与封面到相册（ClipKeep）' : '已保存到相册（ClipKeep）');
  }

  /// 保存图文/图集：每张图片单独落盘，实况图额外保存关联短视频。
  Future<Result<String>> saveImages(
    List<MediaImage> images, {
    int? onlyIndex,
    String? downloadId,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    if (images.isEmpty) {
      return const Err(AppError('没有可保存的图片'));
    }
    final int target = onlyIndex?.clamp(0, images.length - 1) ?? -1;
    final List<MediaImage> queue = onlyIndex == null
        ? images
        : <MediaImage>[images[target]];

    bool saveToGallery = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      saveToGallery = prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
    } catch (_) {
      // 读取失败默认保存到相册。
    }
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }

    final Directory dir =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final String stamp =
        downloadId ?? DateTime.now().millisecondsSinceEpoch.toString();
    int savedImages = 0;
    int savedVideos = 0;

    for (int i = 0; i < queue.length; i++) {
      final MediaImage image = queue[i];
      final int displayIndex = onlyIndex == null ? i : target;
      final String ext = _imageExt(image.primaryUrl);
      final String tempImage = '${dir.path}/clipkeep_img_${stamp}_$i.$ext';
      final String displayName = 'ClipKeep_${stamp}_${displayIndex + 1}.$ext';
      String? tempVideo;
      try {
        await _downloadFile(
          image.urls,
          tempImage,
          (String url) => imageHeadersFor(url),
        );
        if (saveToGallery) {
          await Gal.putImage(tempImage, album: AppConstants.albumName);
        } else {
          final String? saved = await _saveToDownloads(
            tempImage,
            displayName,
            _imageMime(ext),
          );
          if (saved == null) {
            return Err(AppError('保存第 ${displayIndex + 1} 张图片到下载目录失败'));
          }
        }
        savedImages++;

        final MediaStream? live = image.liveVideo;
        if (live != null && live.primaryUrl.isNotEmpty) {
          tempVideo = '${dir.path}/clipkeep_live_${stamp}_$i.mp4';
          await _downloadFile(live.urls, tempVideo, (_) => live.headers);
          if (saveToGallery) {
            await Gal.putVideo(tempVideo, album: AppConstants.albumName);
          } else {
            final String? saved = await _saveToDownloads(
              tempVideo,
              'ClipKeep_${stamp}_${displayIndex + 1}_live.mp4',
              'video/mp4',
            );
            if (saved == null) {
              return Err(AppError('保存第 ${displayIndex + 1} 张的实况视频到下载目录失败'));
            }
          }
          savedVideos++;
        }

        onProgress?.call(
          DownloadProgress(
            fraction: (i + 1) / queue.length,
            phase: '正在保存 ${i + 1}/${queue.length}…',
          ),
        );
      } catch (e) {
        return Err(
          AppError('保存第 ${displayIndex + 1} 张图片失败：${_describe(e)}', cause: e),
        );
      } finally {
        await _cleanupQuietly(<String>[tempImage, ?tempVideo]);
      }
    }

    final String where = saveToGallery
        ? '相册（${AppConstants.albumName}）'
        : 'Download/ClipKeep';
    final String videos = savedVideos > 0 ? '、$savedVideos 个实况视频' : '';
    return Ok('已保存 $savedImages 张图片$videos到$where');
  }

  Future<void> _downloadFile(
    List<String> urls,
    String path,
    Map<String, String> Function(String url) headersOf,
  ) async {
    Object? last;
    for (final String url in urls) {
      try {
        await _dio.download(
          url,
          path,
          options: Options(
            headers: headersOf(url),
            receiveTimeout: const Duration(minutes: 2),
          ),
          deleteOnError: true,
        );
        return;
      } catch (e) {
        last = e;
        await _cleanupQuietly(<String>[path]);
      }
    }
    throw last ?? Exception('没有可用的下载地址');
  }

  String _imageExt(String url) {
    final String path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final String ext in <String>[
      'webp',
      'jpg',
      'jpeg',
      'png',
      'gif',
      'heic',
    ]) {
      if (path.endsWith('.$ext')) {
        return ext == 'jpeg' ? 'jpg' : ext;
      }
    }
    return 'jpg';
  }

  String _imageMime(String ext) {
    switch (ext) {
      case 'webp':
        return 'image/webp';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'heic':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
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
    if (cancelToken?.isCancelled ?? false) {
      return const Err(AppError('已暂停'));
    }

    final String displayName = 'ClipKeep_audio_$stamp.m4a';
    final String? savedPath = await _saveToDownloads(
      tempPath,
      displayName,
      'audio/mp4',
    );

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
      return Ok('已保存音频到 $savedPath');
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
    return Ok('已保存音频到应用目录（卸载后删除）：$fallbackPath');
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
    if (cancelToken?.isCancelled ?? false) {
      return const Err(AppError('已暂停'));
    }

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
    // 抽取本身是阻塞调用，暂停请求只能在这里生效：丢弃音轨，保留视频源供续传。
    if (cancelToken?.isCancelled ?? false) {
      await _cleanupQuietly(<String>[outPath]);
      return const Err(AppError('已暂停'));
    }
    await _cleanupQuietly(<String>[tempVideo]);

    final String displayName = 'ClipKeep_audio_$stamp.m4a';
    final String? savedPath = await _saveToDownloads(
      outPath,
      displayName,
      'audio/mp4',
    );
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
      return Ok('已保存音频到 $savedPath');
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
    return Ok('已保存音频到应用目录（卸载后删除）：$fallbackPath');
  }

  Future<Result<String>> _downloadCoverOnly(
    String? coverUrl,
    String dirPath,
    String stamp,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress, {
    required bool saveToGallery,
  }) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return const Err(AppError('没有可保存的封面'));
    }
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }
    try {
      final coverPath = '$dirPath/clipkeep_cover_$stamp.jpg';
      await _dio.download(
        url,
        coverPath,
        cancelToken: cancelToken,
        options: Options(
          headers: _withCookie(imageHeadersFor(url), url: url),
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (int received, int total) {
          agg.updateStream('cover', received, total);
          onProgress?.call(agg.snapshot());
        },
      );
      agg.finishStreamKey('cover');
      if (cancelToken?.isCancelled ?? false) {
        await _cleanupQuietly(<String>[coverPath]);
        return const Err(AppError('已暂停'));
      }
      final String message;
      if (saveToGallery) {
        await Gal.putImage(coverPath, album: AppConstants.albumName);
        message = '封面已保存到相册（ClipKeep）';
      } else {
        final String? saved = await _saveToDownloads(
          coverPath,
          'ClipKeep_cover_$stamp.jpg',
          'image/jpeg',
        );
        if (saved == null) {
          await _cleanupQuietly(<String>[coverPath]);
          return const Err(AppError('保存封面到下载目录失败（可能缺少存储权限）'));
        }
        message = '封面已保存到 $saved';
      }
      final int coverLen = await File(coverPath).length();
      onProgress?.call(
        DownloadProgress(
          fraction: 1,
          receivedBytes: coverLen,
          totalBytes: coverLen,
        ),
      );
      await _cleanupQuietly(<String>[coverPath]);
      return Ok(message);
    } on GalException {
      return const Err(AppError('保存到相册失败'));
    } catch (e) {
      return Err(AppError('保存封面失败', cause: e));
    }
  }

  Future<bool> _saveCover(
    String? coverUrl,
    String dirPath,
    String stamp, {
    required bool saveToGallery,
  }) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return false;
    }
    try {
      final coverPath = '$dirPath/clipkeep_cover_$stamp.jpg';
      await _dio.download(
        url,
        coverPath,
        options: Options(
          headers: _withCookie(imageHeadersFor(url), url: url),
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (saveToGallery) {
        if (!await _ensureGalleryAccess()) {
          await _cleanupQuietly(<String>[coverPath]);
          return false;
        }
        await Gal.putImage(coverPath, album: AppConstants.albumName);
        await _cleanupQuietly(<String>[coverPath]);
        return true;
      }
      final String? saved = await _saveToDownloads(
        coverPath,
        'ClipKeep_cover_$stamp.jpg',
        'image/jpeg',
      );
      await _cleanupQuietly(<String>[coverPath]);
      return saved != null;
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

  /// 复制成品到系统下载目录 `Download/ClipKeep`，返回相对路径；原生失败返回 null。
  Future<String?> _saveToDownloads(
    String path,
    String displayName,
    String mime,
  ) async {
    try {
      return await _mediaStore.invokeMethod<String>(
        'saveFile',
        <String, String>{
          'path': path,
          'displayName': displayName,
          'mime': mime,
        },
      );
    } catch (_) {
      return null;
    }
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

  /// 删除某个任务在应用目录里的全部临时产物（源流、分片、合并结果、封面）。
  /// 仅在用户删除记录时调用；失败重试需要保留这些文件以续传。
  Future<void> cleanupTemp(String downloadId) async {
    try {
      final Directory dir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final List<String> paths = <String>[
        '${dir.path}/clipkeep_v_$downloadId.m4s',
        '${dir.path}/clipkeep_a_$downloadId.m4s',
        '${dir.path}/clipkeep_av_$downloadId.m4s',
        '${dir.path}/clipkeep_audio_$downloadId.m4a',
        '${dir.path}/clipkeep_cover_$downloadId.jpg',
        '${dir.path}/clipkeep_$downloadId.mp4',
      ];
      for (final String name in <String>[
        'clipkeep_v_$downloadId.m4s',
        'clipkeep_a_$downloadId.m4s',
        'clipkeep_av_$downloadId.m4s',
        'clipkeep_audio_$downloadId.m4a',
      ]) {
        for (int i = 0; i < 64; i++) {
          paths.add('${dir.path}/$name.part$i');
        }
      }
      await _cleanupQuietly(paths);
    } catch (_) {
      // 临时目录不可用时忽略。
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
      agg.beginStream(key, total, initial: total);
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
    // 服务端不支持 Range 时会从头覆盖写，已存在字节不能算作本次进度。
    final int resumeFrom = probe.supported ? existing : 0;
    agg.beginStream(key, total ?? 0, initial: resumeFrom);
    if (resumeFrom > 0) {
      agg.updateStream(key, resumeFrom, total ?? 0);
      onProgress?.call(agg.snapshot());
    }
    final int? to = probe.supported ? (total != null ? total - 1 : null) : null;
    await _downloadRangeAppend(
      url,
      stream.headers,
      destination,
      resumeFrom,
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
    agg.beginStream(key, total, initial: known);
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
      ..._withCookie(headers, url: url),
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
    Response<ResponseBody>? res;
    StreamSubscription<List<int>>? subscription;
    try {
      // 用 stream 而不是 bytes：若服务端忽略 Range 直接回 200，bytes 会把整个文件读进内存。
      res = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, String>{
            ..._withCookie(headers, url: url),
            'Range': 'bytes=0-0',
          },
          validateStatus: (int? status) => status != null && status < 500,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      subscription = res.data?.stream.listen(null);
      final String? contentRange = res.headers.value('content-range');
      if (res.statusCode == 206) {
        if (contentRange == null) {
          // 206 却没有 Content-Range：总大小不可信，退回单连接重下。
          return (supported: false, total: null);
        }
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
    } finally {
      await subscription?.cancel();
    }
  }
}

/// 汇总多个并发流（视频 + 音频）的字节进度。
class _ByteAggregator {
  double scale = 1.0;
  int _finished = 0;
  int _finishedBase = 0;
  final Map<String, int> _recv = <String, int>{};
  final Map<String, int> _tot = <String, int>{};
  final Map<String, int> _base = <String, int>{};
  final DateTime _start = DateTime.now();

  /// [initial] 是续传前已存在的字节，不计入本次速度，避免恢复时出现虚假高速。
  void beginStream(String key, int total, {int initial = 0}) {
    _recv[key] = initial;
    _tot[key] = total > 0 ? total : 0;
    _base[key] = initial;
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
    _finishedBase += _base[key] ?? 0;
    _recv.remove(key);
    _tot.remove(key);
    _base.remove(key);
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
    int started = _finishedBase;
    for (final int value in _base.values) {
      started += value;
    }
    final double elapsed =
        DateTime.now().difference(_start).inMilliseconds / 1000.0;
    final int transferred = received - started;
    final double speed = elapsed > 0 && transferred > 0
        ? transferred / elapsed
        : 0;
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
