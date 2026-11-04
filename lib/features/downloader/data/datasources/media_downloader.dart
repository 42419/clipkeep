import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/result.dart';
import '../../domain/entities/parsed_source.dart';

/// 下载视频/音频流、用 ffmpeg 合并、并保存到相册。
class MediaDownloader {
  MediaDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<Result<String>> download(
    MediaPart part, {
    void Function(double progress)? onProgress,
  }) async {
    final video = part.pickVideo();
    if (video == null || video.primaryUrl.isEmpty) {
      return const Err(AppError('该视频没有可下载的视频流'));
    }
    final audio = part.pickAudio();
    final hasAudio = audio != null && audio.primaryUrl.isNotEmpty;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final videoPath = '${dir.path}/clipkeep_v_$stamp.m4s';
      final audioPath = '${dir.path}/clipkeep_a_$stamp.m4s';
      final outputPath = '${dir.path}/clipkeep_$stamp.mp4';

      await _downloadStream(video, videoPath, (p) => onProgress?.call(p * 0.5));
      if (hasAudio) {
        await _downloadStream(
            audio, audioPath, (p) => onProgress?.call(0.5 + p * 0.4));
      }
      onProgress?.call(0.92);

      final command = hasAudio
          ? '-y -i "$videoPath" -i "$audioPath" -c copy -map 0:v:0 -map 1:a:0 "$outputPath"'
          : '-y -i "$videoPath" -c copy "$outputPath"';
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getOutput();
        return Err(AppError('音视频合并失败', cause: logs));
      }

      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          return const Err(AppError('没有相册写入权限'));
        }
      }
      await Gal.putVideo(outputPath, album: 'ClipKeep');
      onProgress?.call(1.0);
      return Ok(outputPath);
    } on GalException catch (e) {
      return Err(AppError('保存到相册失败', cause: e));
    } catch (e) {
      return Err(AppError('下载失败', cause: e));
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
