import 'package:dio/dio.dart' show CancelToken;
import 'package:url_launcher/url_launcher.dart';

import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'media_naming.dart';
import 'result.dart';

/// web 版下载器：不碰文件系统，只把 `/dl?u=…&n=…` 交给浏览器。
///
/// 接口与 `media_downloader_io.dart` 完全一致，调用方无需感知平台。
/// 浏览器负责进度、续传与落盘，服务端 `/dl` 用 `Content-Disposition` 保证是下载而非播放。
class MediaDownloader {
  MediaDownloader();

  /// 连续触发多个下载时，浏览器可能要求用户确认，留一点间隔。
  static const Duration _gap = Duration(milliseconds: 400);

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
    final String? url = coverOnly
        ? _normalize(coverUrl)
        : _normalize(part.pickVideoQuality(videoQuality)?.primaryUrl);
    if (url == null) {
      return const Err(AppError('没有可下载的地址'));
    }

    final String name = _fileName(
      fileStem,
      coverOnly ? _imageExtension(url) : '.mp4',
      fallback: coverOnly ? 'ClipKeep_cover' : 'ClipKeep',
    );

    if (!await _open(url, name)) {
      return const Err(AppError('浏览器拒绝了下载请求'));
    }

    // 交给浏览器后就没有真实进度可报了，直接给一个完成的快照。
    onProgress?.call(const DownloadProgress(fraction: 1));
    onSavedFiles?.call(<SavedMediaFile>[
      SavedMediaFile(name: name, mime: coverOnly ? 'image/jpeg' : 'video/mp4'),
    ]);
    return Ok(url);
  }

  /// 图集逐张下载；实况图只取静态图，合成的 Motion Photo 在 web 上不支持。
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

    final String stem = (fileStem?.trim().isNotEmpty ?? false)
        ? fileStem!.trim()
        : 'ClipKeep_${DateTime.now().millisecondsSinceEpoch}';
    final List<SavedMediaFile> saved = <SavedMediaFile>[];

    for (int i = 0; i < queue.length; i++) {
      final String? url = _normalize(queue[i].primaryUrl);
      if (url == null) {
        continue;
      }
      final String name = fitFileName(
        queue.length > 1 ? '${stem}_${i + 1}' : stem,
        _imageExtension(url),
      );
      if (await _open(url, name)) {
        saved.add(SavedMediaFile(name: name, mime: 'image/jpeg'));
      }
      if (i < queue.length - 1) {
        await Future<void>.delayed(_gap);
      }
    }

    if (saved.isEmpty) {
      return const Err(AppError('浏览器拒绝了下载请求'));
    }
    onProgress?.call(const DownloadProgress(fraction: 1));
    onSaved?.call(saved.length, 0);
    onSavedFiles?.call(saved);
    return Ok('已交给浏览器 ${saved.length} 个文件');
  }

  Future<int> cacheBytes() async => 0;

  Future<int> clearCache() async => 0;

  Future<Result<String>> openSaved(List<String> names) async =>
      const Err(AppError('网页版不支持打开本地文件'));

  Future<Result<String>> shareSaved(List<String> names) async =>
      const Err(AppError('网页版不支持分享本地文件'));

  Future<int?> freeBytes() async => null;

  Future<int?> probeSelectionTotal(MediaPart part, {int? videoQuality}) async =>
      null;

  Future<Result<String>> composeMotionPhoto({
    required String imagePath,
    required String videoPath,
  }) async => const Err(AppError('网页版不支持合成实况图'));

  Future<Result<String>> saveLocalPair({
    required String imagePath,
    required String videoPath,
  }) async => const Err(AppError('网页版不支持保存本地文件'));

  Future<void> cleanupTemp(String downloadId) async {}

  Future<void> cleanupOrphans(Set<String> keepIds) async {}

  // ---------- 内部 ----------

  /// 拼同源下载地址，让网关补 `Content-Disposition`。
  Future<bool> _open(String rawUrl, String filename) async {
    final Uri target = Uri.base.replace(
      path: '/dl',
      queryParameters: <String, String>{'u': rawUrl, 'n': filename},
    );
    try {
      // `_self` 走当前页导航：响应带 attachment 时浏览器不会跳走，直接落文件。
      return await launchUrl(
        target,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
    } catch (_) {
      return false;
    }
  }

  String _fileName(String? stem, String extension, {required String fallback}) {
    final String base = (stem?.trim().isNotEmpty ?? false)
        ? stem!.trim()
        : '${fallback}_${DateTime.now().millisecondsSinceEpoch}';
    return fitFileName(base, extension);
  }

  String? _normalize(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) {
      return null;
    }
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    return null;
  }

  /// 图片扩展名只能从 URL 猜，猜不到就用 jpg。
  String _imageExtension(String url) {
    final String lower = url.toLowerCase();
    for (final String ext in <String>[
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.heic',
      '.avif',
    ]) {
      if (lower.contains(ext)) {
        return ext;
      }
    }
    return '.jpg';
  }
}
