import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_live_motion/flutter_live_motion.dart';

import 'image_headers.dart';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'media_naming.dart';
import 'result.dart';

/// 下载视频流，支持按画质、仅封面、视频+封面，并保存到相册/下载目录。
class MediaDownloader {
  MediaDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const MethodChannel _mediaStore = MethodChannel(
    'clipkeep/media_store',
  );

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
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    String? downloadId,
    String? fileStem,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) async {
    bool saveToGallery = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      saveToGallery = prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
    } catch (_) {
      // 读取失败默认保存到相册。
    }
    try {
      if (saveToGallery && !await _ensureGalleryAccess()) {
        return const Err(AppError('没有相册写入权限'));
      }
      final dir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      // downloadId 稳定（= task.id），使暂停/重试能命中同一批临时文件，实现断点续传。
      final stamp =
          downloadId ?? DateTime.now().millisecondsSinceEpoch.toString();
      final String base = (fileStem?.trim().isNotEmpty ?? false)
          ? fileStem!.trim()
          : 'ClipKeep_$stamp';
      final agg = _ByteAggregator();
      if (coverOnly) {
        return await _downloadCoverOnly(
          coverUrl,
          dir.path,
          stamp,
          base,
          agg,
          cancelToken,
          onProgress,
          onSavedFiles: onSavedFiles,
          saveToGallery: saveToGallery,
        );
      }
      return await _downloadVideo(
        part,
        dir.path,
        stamp,
        base,
        videoQuality: videoQuality,
        saveToGallery: saveToGallery,
        saveCover: saveCover,
        coverUrl: coverUrl,
        agg: agg,
        cancelToken: cancelToken,
        onProgress: onProgress,
        onSavedFiles: onSavedFiles,
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
    String stamp,
    String base, {
    int? videoQuality,
    required bool saveToGallery,
    required bool saveCover,
    String? coverUrl,
    required _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) async {
    final video = part.pickVideoQuality(videoQuality);
    if (video == null || video.primaryUrl.isEmpty) {
      return const Err(AppError('该视频没有可下载的视频流'));
    }
    final videoPath = '$dirPath/clipkeep_v_$stamp.m4s';
    final String finalName = fitFileName(base, '.mp4');
    final outputPath = '$dirPath/$finalName';

    agg.scale = 1;
    await _downloadStream(
      video,
      videoPath,
      agg,
      'video',
      cancelToken,
      onProgress,
    );
    agg.finishStreamKey('video');
    if (cancelToken?.isCancelled ?? false) {
      return const Err(AppError('已暂停'));
    }

    // 抖音返回的是带音轨的 MP4，不需要再合并；复制成可读文件名供入库。
    try {
      final File source = File(videoPath);
      final File output = File(outputPath);
      if (await output.exists()) {
        await output.delete();
      }
      await source.copy(outputPath);
    } catch (e) {
      await _cleanupQuietly(<String>[outputPath]);
      return Err(AppError('保存视频文件失败：${_describe(e)}', cause: e));
    }

    final int outLen = await File(outputPath).length();
    onProgress?.call(
      DownloadProgress(fraction: 1, receivedBytes: outLen, totalBytes: outLen),
    );
    if (cancelToken?.isCancelled ?? false) {
      await _cleanupQuietly(<String>[outputPath]);
      return const Err(AppError('已暂停'));
    }

    final List<SavedMediaFile> savedFiles = <SavedMediaFile>[
      SavedMediaFile(name: finalName, mime: 'video/mp4'),
    ];

    if (!saveToGallery) {
      final String? saved = await _saveToDownloads(
        outputPath,
        finalName,
        'video/mp4',
      );
      if (saved == null) {
        await _cleanupQuietly(<String>[outputPath]);
        return const Err(AppError('保存到下载目录失败（可能缺少存储权限）'));
      }
      SavedMediaFile? cover;
      if (saveCover) {
        cover = await _saveCover(coverUrl, dirPath, base, saveToGallery: false);
        if (cover != null) {
          savedFiles.add(cover);
        }
      }
      onSavedFiles?.call(savedFiles);
      await _cleanupQuietly(<String>[videoPath, outputPath]);
      return Ok(cover != null ? '已保存视频与封面到 Download/ClipKeep' : '已保存到 $saved');
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

    SavedMediaFile? cover;
    if (saveCover) {
      cover = await _saveCover(
        coverUrl,
        dirPath,
        base,
        saveToGallery: saveToGallery,
      );
      if (cover != null) {
        savedFiles.add(cover);
      }
    }
    onSavedFiles?.call(savedFiles);
    await _cleanupQuietly(<String>[videoPath, outputPath]);
    return Ok(cover != null ? '已保存视频与封面到相册（ClipKeep）' : '已保存到相册（ClipKeep）');
  }

  /// 临时分片、合成缓存与更新安装包占用的空间。
  Future<int> cacheBytes() async {
    int total = 0;
    for (final Directory dir in await _cacheDirs()) {
      if (!await dir.exists()) {
        continue;
      }
      try {
        await for (final FileSystemEntity entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && _isCacheFile(entity.path)) {
            total += await entity.length();
          }
        }
      } catch (_) {
        // 单个目录读失败忽略。
      }
    }
    return total;
  }

  /// 清理缓存，返回释放的字节数；调用方需保证没有任务在下载。
  Future<int> clearCache() async {
    int freed = 0;
    for (final Directory dir in await _cacheDirs()) {
      if (!await dir.exists()) {
        continue;
      }
      try {
        await for (final FileSystemEntity entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !_isCacheFile(entity.path)) {
            continue;
          }
          try {
            final int size = await entity.length();
            await entity.delete();
            freed += size;
          } catch (_) {
            // 正在使用的文件跳过。
          }
        }
      } catch (_) {
        // 忽略。
      }
    }
    return freed;
  }

  Future<List<Directory>> _cacheDirs() async {
    final List<Directory> dirs = <Directory>[];
    try {
      final Directory? external = await getExternalStorageDirectory();
      if (external != null) {
        dirs.add(external);
      }
    } catch (_) {}
    try {
      dirs.add(await getTemporaryDirectory());
    } catch (_) {}
    return dirs;
  }

  bool _isCacheFile(String path) {
    final String name = path.split(Platform.pathSeparator).last;
    if (name.startsWith('clipkeep_') || name.startsWith('MVIMG_')) {
      return true;
    }
    // update 缓存：<cache>/updates/app-arm64-v8a-release.apk 与 update.json
    return path.contains(
      '${Platform.pathSeparator}updates${Platform.pathSeparator}',
    );
  }

  /// 打开已保存的文件（按文件名回查 MediaStore）。
  Future<Result<String>> openSaved(List<String> names) =>
      _mediaAction('openMedia', names, '打开');

  /// 分享已保存的文件。
  Future<Result<String>> shareSaved(List<String> names) =>
      _mediaAction('shareMedia', names, '分享');

  Future<Result<String>> _mediaAction(
    String method,
    List<String> names,
    String label,
  ) async {
    if (names.isEmpty) {
      return Err(AppError('这条记录没有可$label的文件'));
    }
    try {
      await _mediaStore.invokeMethod<void>(method, <String, Object>{
        'names': names,
      });
      return Ok('已$label');
    } on PlatformException catch (e) {
      return Err(AppError(e.message ?? '$label失败'));
    } on MissingPluginException {
      return Err(AppError('当前版本不支持$label文件'));
    } catch (e) {
      return Err(AppError('$label失败：$e'));
    }
  }

  /// 当前应用外部目录的可用字节数；原生失败返回 null（不阻塞下载）。
  Future<int?> freeBytes() async {
    try {
      return await _mediaStore.invokeMethod<int>('freeBytes');
    } catch (_) {
      return null;
    }
  }

  /// 续传前探测当前选择的总字节数；任一路无法确认就返回 null。
  Future<int?> probeSelectionTotal(MediaPart part, {int? videoQuality}) async {
    try {
      final MediaStream? video = part.pickVideoQuality(videoQuality);
      if (video == null) {
        return null;
      }
      final ({bool supported, int? total}) videoProbe = await _probeRange(
        video.primaryUrl,
        video.headers,
        null,
      );
      if (videoProbe.total == null) {
        return null;
      }
      int total = videoProbe.total!;
      final MediaStream? audio = part.pickAudio();
      if (audio != null) {
        final ({bool supported, int? total}) audioProbe = await _probeRange(
          audio.primaryUrl,
          audio.headers,
          null,
        );
        if (audioProbe.total == null) {
          return null;
        }
        total += audioProbe.total!;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// 保存图文/图集：每张图片单独落盘，实况图额外保存关联短视频。
  ///
  /// [separateLive] 为 true 时不做 Motion Photo 合成，直接把图片和实况视频
  /// 分别保存；用于相册不识别第三方动态照片的机型。
  Future<Result<String>> saveImages(
    List<MediaImage> images, {
    int? onlyIndex,
    String? downloadId,
    String? fileStem,
    bool separateLive = false,
    void Function(DownloadProgress progress)? onProgress,
    void Function(int savedItems, int liveItems)? onSaved,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) async {
    if (images.isEmpty) {
      return const Err(AppError('没有可保存的图片'));
    }
    final int target = onlyIndex?.clamp(0, images.length - 1) ?? -1;
    final List<MediaImage> queue = onlyIndex == null
        ? images
        : <MediaImage>[images[target]];

    final bool saveToGallery = await _readSaveToGallery();
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }

    final Directory dir =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final String stamp =
        downloadId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final String base = (fileStem?.trim().isNotEmpty ?? false)
        ? fileStem!.trim()
        : 'ClipKeep_$stamp';
    int savedImages = 0;
    int savedMotions = 0;
    int savedVideos = 0;

    for (int i = 0; i < queue.length; i++) {
      final MediaImage image = queue[i];
      final int displayIndex = onlyIndex == null ? i : target;
      final String ext = _imageExt(image.primaryUrl);
      final String indexLabel = (displayIndex + 1).toString().padLeft(2, '0');
      final String imageName = fitFileName('$base-$indexLabel', '.$ext');
      final String liveName = fitFileName('$base-$indexLabel-live', '.mp4');
      final String motionName = fitFileName('$base-$indexLabel-MP', '.jpg');
      final String tempImage = '${dir.path}/$imageName';
      final List<SavedMediaFile> savedHere = <SavedMediaFile>[];
      String? tempJpg;
      String? tempVideo;
      String? tempMotion;
      String? motionPath;
      try {
        await _downloadFile(
          image.urls,
          tempImage,
          (String url) => imageHeadersFor(url),
        );
        if (!await _isImageFile(tempImage)) {
          throw Exception('图片地址返回的不是有效图片');
        }

        final MediaStream? rawLive = image.liveVideo;
        final MediaStream? live =
            rawLive != null && rawLive.primaryUrl.isNotEmpty ? rawLive : null;
        if (live != null) {
          tempVideo = '${dir.path}/$liveName';
          await _downloadFile(live.urls, tempVideo, (_) => live.headers);
          if (!await _isMp4File(tempVideo)) {
            throw Exception('实况视频地址返回的不是有效 MP4');
          }
        }

        if (live != null && separateLive) {
          await _saveImageFile(tempImage, imageName, ext, saveToGallery);
          await _saveVideoFile(tempVideo!, liveName, saveToGallery);
          savedImages++;
          savedVideos++;
          savedHere
            ..add(SavedMediaFile(name: imageName, mime: _imageMime(ext)))
            ..add(SavedMediaFile(name: liveName, mime: 'video/mp4'));
        } else {
          bool motionSaved = false;
          if (live != null) {
            try {
              // 一律转成去掉元数据的 JPG：插件遇到自带 XMP 的原图只会改已有
              // 长度字段，不会补 Motion Photo 标记，会产出“伪实况”普通 JPEG。
              tempJpg = '${dir.path}/clipkeep_img_${stamp}_$i.jpg';
              await _convertToJpg(tempImage, tempJpg);
              final dynamic generated = await FlutterLiveMotion().generate(
                imagePath: tempJpg,
                videoPath: tempVideo!,
              );
              if (generated is String && generated.isNotEmpty) {
                tempMotion = generated;
                // 插件固定输出 MVIMG_xxx_MP.jpg，复制成可读文件名再入库。
                motionPath = '${dir.path}/$motionName';
                await File(generated).copy(motionPath);
                await _saveImageFile(
                  motionPath,
                  motionName,
                  'jpg',
                  saveToGallery,
                );
                savedMotions++;
                motionSaved = true;
                savedHere.add(
                  SavedMediaFile(name: motionName, mime: 'image/jpeg'),
                );
              }
            } catch (_) {
              // 合成失败时回退为图片 + 独立视频，至少不丢内容。
            }
          }

          if (!motionSaved) {
            await _saveImageFile(tempImage, imageName, ext, saveToGallery);
            savedImages++;
            savedHere.add(
              SavedMediaFile(name: imageName, mime: _imageMime(ext)),
            );
            if (live != null && tempVideo != null) {
              await _saveVideoFile(tempVideo, liveName, saveToGallery);
              savedVideos++;
              savedHere.add(SavedMediaFile(name: liveName, mime: 'video/mp4'));
            }
          }
        }

        onSavedFiles?.call(savedHere);

        onSaved?.call(savedImages + savedMotions, savedMotions + savedVideos);
        onProgress?.call(
          DownloadProgress(
            fraction: (i + 1) / queue.length,
            phase: '正在保存 ${i + 1}/${queue.length}…',
          ),
        );
      } catch (e) {
        final int savedCount = savedImages + savedMotions;
        if (savedCount > 0) {
          // 部分图片已经落盘：不能返回纯错误让用户重试（会产生重复），
          // 用带失败信息的成功结果记录已完成项。
          final String where = saveToGallery
              ? '相册（${AppConstants.albumName}）'
              : 'Download/ClipKeep';
          return Ok(
            '已保存 $savedCount 项到$where；第 ${displayIndex + 1} 张失败：${_describe(e)}',
          );
        }
        return Err(
          AppError('保存第 ${displayIndex + 1} 张图片失败：${_describe(e)}', cause: e),
        );
      } finally {
        await _cleanupQuietly(<String>[
          tempImage,
          ?tempJpg,
          ?tempVideo,
          ?tempMotion,
          ?motionPath,
        ]);
      }
    }

    final String where = saveToGallery
        ? '相册（${AppConstants.albumName}）'
        : 'Download/ClipKeep';
    final List<String> saved = <String>[
      if (savedImages > 0) '$savedImages 张图片',
      if (savedMotions > 0) '$savedMotions 张实况照片',
      if (savedVideos > 0) '$savedVideos 个实况视频',
    ];
    return Ok('已保存 ${saved.join('、')}到$where');
  }

  /// 手动把本地图片 + 视频合成为 Motion Photo 并保存。
  ///
  /// 图片一律先转成去掉元数据的 JPG，避免原图自带 XMP 时插件只更新长度字段、
  /// 不补 Motion Photo 标记，最终得到一张普通 JPEG。
  Future<Result<String>> composeMotionPhoto({
    required String imagePath,
    required String videoPath,
  }) async {
    final bool saveToGallery = await _readSaveToGallery();
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }
    final Directory dir =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String jpgPath = '${dir.path}/clipkeep_compose_$stamp.jpg';
    String? generated;
    try {
      if (!await File(imagePath).exists()) {
        return const Err(AppError('图片文件不存在'));
      }
      if (!await File(videoPath).exists()) {
        return const Err(AppError('视频文件不存在'));
      }
      if (!await _isImageFile(imagePath)) {
        return const Err(AppError('选择的图片无法识别'));
      }
      if (!await _isMp4File(videoPath)) {
        return const Err(AppError('选择的视频不是有效的 MP4'));
      }
      await _convertToJpg(imagePath, jpgPath);
      final dynamic out = await FlutterLiveMotion().generate(
        imagePath: jpgPath,
        videoPath: videoPath,
      );
      if (out is! String || out.isEmpty) {
        return const Err(AppError('合成失败：没有生成文件'));
      }
      generated = out;
      await _saveImageFile(
        out,
        'ClipKeep_motion_${stamp}_MP.jpg',
        'jpg',
        saveToGallery,
      );
      final String where = saveToGallery
          ? '相册（${AppConstants.albumName}）'
          : 'Download/ClipKeep';
      return Ok('已保存实况照片到$where');
    } catch (e) {
      return Err(AppError('合成实况照片失败：${_describe(e)}', cause: e));
    } finally {
      await _cleanupQuietly(<String>[jpgPath, ?generated]);
    }
  }

  /// 把本地图片和视频分别保存（不做合成），用于相册不识别动态照片的机型。
  Future<Result<String>> saveLocalPair({
    required String imagePath,
    required String videoPath,
  }) async {
    final bool saveToGallery = await _readSaveToGallery();
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      if (!await File(imagePath).exists()) {
        return const Err(AppError('图片文件不存在'));
      }
      if (!await File(videoPath).exists()) {
        return const Err(AppError('视频文件不存在'));
      }
      if (!await _isImageFile(imagePath)) {
        return const Err(AppError('选择的图片无法识别'));
      }
      if (!await _isMp4File(videoPath)) {
        return const Err(AppError('选择的视频不是有效的 MP4'));
      }
      final String ext = _pathExt(imagePath);
      await _saveImageFile(
        imagePath,
        'ClipKeep_$stamp.$ext',
        ext,
        saveToGallery,
      );
      await _saveVideoFile(
        videoPath,
        'ClipKeep_${stamp}_live.mp4',
        saveToGallery,
      );
      final String where = saveToGallery
          ? '相册（${AppConstants.albumName}）'
          : 'Download/ClipKeep';
      return Ok('已保存图片和视频到$where');
    } catch (e) {
      return Err(AppError('保存图片和视频失败：${_describe(e)}', cause: e));
    }
  }

  Future<bool> _readSaveToGallery() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(AppConstants.prefSaveToGallery) ?? true;
    } catch (_) {
      // 读取失败默认保存到相册。
      return true;
    }
  }

  String _pathExt(String path) {
    final String lower = path.toLowerCase();
    for (final String ext in <String>[
      'webp',
      'jpg',
      'jpeg',
      'png',
      'gif',
      'heic',
      'avif',
    ]) {
      if (lower.endsWith('.$ext')) {
        return ext == 'jpeg' ? 'jpg' : ext;
      }
    }
    return 'jpg';
  }

  Future<void> _saveImageFile(
    String path,
    String displayName,
    String ext,
    bool saveToGallery,
  ) async {
    if (saveToGallery) {
      await Gal.putImage(path, album: AppConstants.albumName);
      return;
    }
    final String? saved = await _saveToDownloads(
      path,
      displayName,
      _imageMime(ext),
    );
    if (saved == null) {
      throw AppError('保存图片到下载目录失败');
    }
  }

  Future<void> _saveVideoFile(
    String path,
    String displayName,
    bool saveToGallery,
  ) async {
    if (saveToGallery) {
      await Gal.putVideo(path, album: AppConstants.albumName);
      return;
    }
    final String? saved = await _saveToDownloads(
      path,
      displayName,
      'video/mp4',
    );
    if (saved == null) {
      throw AppError('保存实况视频到下载目录失败');
    }
  }

  /// 把 WebP/PNG 等转成 Motion Photo 所需的 JPEG，并去掉原图元数据。
  Future<void> _convertToJpg(String input, String output) async {
    try {
      await _mediaStore.invokeMethod<void>('convertToJpeg', <String, Object>{
        'input': input,
        'output': output,
      });
    } on PlatformException catch (e) {
      throw Exception('图片转 JPEG 失败：${e.message ?? e.code}');
    }
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

  Future<bool> _isImageFile(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists() || await file.length() < 12) {
        return false;
      }
      final RandomAccessFile raf = await file.open();
      try {
        final List<int> b = await raf.read(12);
        if (b[0] == 0xFF && b[1] == 0xD8) {
          return true; // JPEG
        }
        if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
          return true; // PNG
        }
        if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
          return true; // GIF
        }
        if (b[0] == 0x52 &&
            b[1] == 0x49 &&
            b[2] == 0x46 &&
            b[3] == 0x46 &&
            b[8] == 0x57 &&
            b[9] == 0x45 &&
            b[10] == 0x42 &&
            b[11] == 0x50) {
          return true; // WebP
        }
        // HEIC/HEIF/AVIF: ....ftyp + brand
        if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
          final String brand = String.fromCharCodes(b.sublist(8, 12));
          return <String>[
            'heic',
            'heix',
            'hevc',
            'heim',
            'heis',
            'mif1',
            'msf1',
            'avif',
            'avis',
          ].contains(brand);
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isMp4File(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists() || await file.length() < 12) {
        return false;
      }
      final RandomAccessFile raf = await file.open();
      try {
        final List<int> b = await raf.read(12);
        return b[4] == 0x66 &&
            b[5] == 0x74 &&
            b[6] == 0x79 &&
            b[7] == 0x70; // ftyp
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
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
      'avif',
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
      case 'avif':
        return 'image/avif';
      default:
        return 'image/jpeg';
    }
  }

  Future<Result<String>> _downloadCoverOnly(
    String? coverUrl,
    String dirPath,
    String stamp,
    String base,
    _ByteAggregator agg,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress, {
    required bool saveToGallery,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return const Err(AppError('没有可保存的封面'));
    }
    if (saveToGallery && !await _ensureGalleryAccess()) {
      return const Err(AppError('没有相册写入权限'));
    }
    final String ext = _imageExt(url);
    final String name = fitFileName('$base-cover', '.$ext');
    try {
      final coverPath = '$dirPath/$name';
      await _dio.download(
        url,
        coverPath,
        cancelToken: cancelToken,
        options: Options(
          headers: imageHeadersFor(url),
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
      if (!await _isImageFile(coverPath)) {
        await _cleanupQuietly(<String>[coverPath]);
        return const Err(AppError('封面地址返回的不是有效图片'));
      }
      final String message;
      if (saveToGallery) {
        await Gal.putImage(coverPath, album: AppConstants.albumName);
        message = '封面已保存到相册（ClipKeep）';
      } else {
        final String? saved = await _saveToDownloads(
          coverPath,
          name,
          _imageMime(ext),
        );
        if (saved == null) {
          await _cleanupQuietly(<String>[coverPath]);
          return const Err(AppError('保存封面到下载目录失败（可能缺少存储权限）'));
        }
        message = '封面已保存到 $saved';
      }
      onSavedFiles?.call(<SavedMediaFile>[
        SavedMediaFile(name: name, mime: _imageMime(ext)),
      ]);
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

  Future<SavedMediaFile?> _saveCover(
    String? coverUrl,
    String dirPath,
    String base, {
    required bool saveToGallery,
  }) async {
    final String? url = _normalizeUrl(coverUrl);
    if (url == null) {
      return null;
    }
    final String ext = _imageExt(url);
    final String name = fitFileName('$base-cover', '.$ext');
    try {
      final coverPath = '$dirPath/$name';
      await _dio.download(
        url,
        coverPath,
        options: Options(
          headers: imageHeadersFor(url),
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (!await _isImageFile(coverPath)) {
        await _cleanupQuietly(<String>[coverPath]);
        return null;
      }
      if (saveToGallery) {
        if (!await _ensureGalleryAccess()) {
          await _cleanupQuietly(<String>[coverPath]);
          return null;
        }
        await Gal.putImage(coverPath, album: AppConstants.albumName);
        await _cleanupQuietly(<String>[coverPath]);
        return SavedMediaFile(name: name, mime: _imageMime(ext));
      }
      final String? saved = await _saveToDownloads(
        coverPath,
        name,
        _imageMime(ext),
      );
      await _cleanupQuietly(<String>[coverPath]);
      return saved == null
          ? null
          : SavedMediaFile(name: name, mime: _imageMime(ext));
    } catch (_) {
      return null;
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
      return await _mediaStore
          .invokeMethod<String>('saveFile', <String, String>{
            'path': path,
            'displayName': displayName,
            'mime': mime,
          })
          .timeout(const Duration(minutes: 2));
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
        for (final String ext in <String>[
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'heic',
          'avif',
        ])
          '${dir.path}/clipkeep_cover_$downloadId.$ext',
        '${dir.path}/clipkeep_$downloadId.mp4',
      ];
      for (int i = 0; i < 64; i++) {
        paths.add('${dir.path}/clipkeep_v_$downloadId.m4s.part$i');
      }
      await _cleanupQuietly(paths);
    } catch (_) {
      // 临时目录不可用时忽略。
    }
  }

  /// 清理不在现有任务列表里的临时文件（启动时调用，回收被杀进程遗留的分片）。
  Future<void> cleanupOrphans(Set<String> keepIds) async {
    try {
      final Directory dir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        final String name = entity.path.split(Platform.pathSeparator).last;
        // 这里只扫应用私有外部目录的顶层：除了可读文件名的临时产物，
        // 只有以任务 id 命名的分片；成品都在子目录 ClipKeep/ 或系统相册。
        if (keepIds.any((String id) => id.isNotEmpty && name.contains(id))) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {
          // 单个文件删除失败不影响其它文件。
        }
      }
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
    for (int i = 0; i < candidates.length; i++) {
      try {
        await _downloadStreamFrom(
          candidates[i],
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
        // 还有备用地址：不能把不同镜像拼进同一临时文件，清掉后从零试下一地址。
        // 最后一个也失败时保留已有分片，交给“继续/重试”复用。
        if (i < candidates.length - 1) {
          await _cleanupQuietly(<String>[
            destination,
            for (int j = 0; j < 64; j++) '$destination.part$j',
          ]);
        }
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
    // 只有服务端确认支持 Range 且长度完全相等时才信任旧文件；
    // 200 的 Content-Length 可能来自 HTML 错误页，不能用于“已完成”判断。
    final int destExisting = await _existingLength(destination);
    if (probe.supported && total != null && destExisting == total) {
      agg.beginStream(key, total, initial: total);
      agg.updateStream(key, total, total);
      onProgress?.call(agg.snapshot());
      return;
    }
    if (destExisting > 0 && (total == null || destExisting > total)) {
      await _cleanupQuietly(<String>[destination]);
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
        // 分片失败：清掉不完整分片，保留目标文件；回退单连接可继续续传。
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
      expectedLength: total,
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
          expectedLength: expected,
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
    int? expectedLength,
  }) async {
    final int from = rangeFrom ?? existing;
    final Map<String, String> requestHeaders = <String, String>{
      ...headers,
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
    final String contentType = (res.headers.value('content-type') ?? '')
        .toLowerCase();
    if (contentType.contains('text/html') ||
        contentType.contains('application/json') ||
        contentType.contains('text/plain')) {
      throw Exception('下载地址返回了错误页（$contentType）');
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
    if (expectedLength != null && received != expectedLength) {
      throw Exception('下载长度不完整：$received/$expectedLength 字节');
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
          headers: <String, String>{...headers, 'Range': 'bytes=0-0'},
          validateStatus: (int? status) => status != null && status < 500,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      subscription = res.data?.stream.listen(null);
      final String contentType = (res.headers.value('content-type') ?? '')
          .toLowerCase();
      if (contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          contentType.contains('text/plain')) {
        throw Exception('探测下载地址返回了错误页（$contentType）');
      }
      final String? contentRange = res.headers.value('content-range');
      if (res.statusCode == 206) {
        if (contentRange == null) {
          // 206 却没有 Content-Range：总大小不可信，退回单连接重下。
          return (supported: false, total: null);
        }
        final String totalPart = contentRange.split('/').last;
        return (supported: true, total: int.tryParse(totalPart));
      }
      if (res.statusCode == 200) {
        final int? length = int.tryParse(
          res.headers.value('content-length') ?? '',
        );
        return (
          supported: false,
          total: (length != null && length > 0) ? length : null,
        );
      }
      // 403/404/416 等错误页不能当成视频长度，交给调用方换地址或报错。
      throw Exception('探测下载地址失败：HTTP ${res.statusCode}');
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
