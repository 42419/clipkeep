import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../viewmodels/parsed_source.dart';
import 'result.dart';

/// 下载视频/音频流，支持按画质选择、仅音频、保存封面，并保存到相册。
class MediaDownloader {
  MediaDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const MethodChannel _mediaStore =
      MethodChannel('clipkeep/media_store');

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
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch.toString();
      if (coverOnly) {
        return await _downloadCoverOnly(coverUrl, dir.path, stamp,
            onProgress: onProgress);
      }
      if (audioOnly) {
        return await _downloadAudioOnly(part, dir.path, stamp,
            coverUrl: coverUrl, saveCover: saveCover, onProgress: onProgress);
      }
      return await _downloadVideo(part, dir.path, stamp,
          videoQuality: videoQuality,
          coverUrl: coverUrl,
          saveCover: saveCover,
          onProgress: onProgress);
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
    String? coverUrl,
    required bool saveCover,
    void Function(double progress)? onProgress,
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

    await _downloadStream(video, videoPath, (p) => onProgress?.call(p * 0.5));
    if (hasAudio) {
      await _downloadStream(
          audio, audioPath, (p) => onProgress?.call(0.5 + p * 0.35));
    }
    onProgress?.call(0.88);

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
    onProgress?.call(1.0);
    await _cleanupQuietly(<String>[videoPath, audioPath, outputPath]);
    return Ok(coverSaved ? '已保存视频与封面（ClipKeep）' : '已保存到相册（ClipKeep）');
  }

  Future<Result<String>> _downloadAudioOnly(
    MediaPart part,
    String dirPath,
    String stamp, {
    String? coverUrl,
    required bool saveCover,
    void Function(double progress)? onProgress,
  }) async {
    final audio = part.pickAudio();
    if (audio == null || audio.primaryUrl.isEmpty) {
      return const Err(AppError('没有可下载的音频流'));
    }
    final tempPath = '$dirPath/clipkeep_a_$stamp.m4s';
    await _downloadStream(audio, tempPath, (p) => onProgress?.call(p * 0.85));

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

    bool coverSaved = false;
    if (saveCover) {
      coverSaved = await _saveCover(coverUrl, dirPath, stamp);
    }
    onProgress?.call(1.0);

    if (savedPath != null) {
      await _cleanupQuietly(<String>[tempPath]);
      return Ok('已保存音频到 下载/ClipKeep：$displayName${coverSaved ? '（含封面）' : ''}');
    }

    // 通道不可用时回退到 App 私有目录。
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
    return Ok('已保存音频：$fallbackPath${coverSaved ? '（含封面）' : ''}');
  }

  Future<Result<String>> _downloadCoverOnly(
    String? coverUrl,
    String dirPath,
    String stamp, {
    void Function(double progress)? onProgress,
  }) async {
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
        options: Options(
          headers: _imageHeaders,
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
      await Gal.putImage(coverPath, album: AppConstants.albumName);
      onProgress?.call(1.0);
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
    void Function(double progress) onProgress,
  ) async {
    await _dio.download(
      stream.primaryUrl,
      destination,
      options: Options(
        headers: stream.headers,
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 30),
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          onProgress(received / total);
        }
      },
    );
  }
}
