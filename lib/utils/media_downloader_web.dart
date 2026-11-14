import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web/web.dart' as web;

import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'media_naming.dart';
import 'result.dart';

/// web 版下载器：不碰文件系统，只把链接交给浏览器。
///
/// 单个文件走 `/dl` 直接下载；多个文件走 `/api/bundle`，由服务端压成一个 zip。
/// 后者是必需的 —— 浏览器会拦截连续触发的多个下载，用户往往只收到第一个。
class MediaDownloader {
  MediaDownloader();

  /// 打包走同源接口，页面与 `/api` 同一个域名，不存在 CORS。
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: Uri.base.origin,
      connectTimeout: const Duration(seconds: 10),
      // 服务端最多压 3 分钟，客户端多等一会儿。
      receiveTimeout: const Duration(minutes: 4),
      validateStatus: (int? status) => status != null && status < 500,
    ),
  );

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

    final List<_Outgoing> outgoing = <_Outgoing>[
      _Outgoing(
        url,
        _fileName(
          fileStem,
          coverOnly ? _imageExtension(url) : '.mp4',
          fallback: coverOnly ? 'ClipKeep_cover' : 'ClipKeep',
        ),
        coverOnly ? 'image/jpeg' : 'video/mp4',
      ),
    ];

    // 「视频+封面」：主文件之外再补一张封面，两个一起打包。
    if (!coverOnly && saveCover) {
      final String? cover = _normalize(coverUrl);
      if (cover != null) {
        outgoing.add(
          _Outgoing(
            cover,
            _fileName(
              '${(fileStem ?? 'ClipKeep').trim()}_cover',
              _imageExtension(cover),
              fallback: 'ClipKeep_cover',
            ),
            'image/jpeg',
          ),
        );
      }
    }

    final _Delivery delivery = await _deliver(
      outgoing,
      fileStem ?? 'ClipKeep',
    );
    if (!delivery.ok) {
      return Err(AppError(delivery.error ?? '浏览器拒绝了下载请求'));
    }

    onProgress?.call(const DownloadProgress(fraction: 1));
    onSavedFiles?.call(
      outgoing
          .map((item) => SavedMediaFile(name: item.name, mime: item.mime))
          .toList(),
    );
    return Ok(url);
  }

  /// 图集逐张下载。`separateLive` 为真时，实况图会额外带上 `_live.mp4`；
  /// 浏览器里没法合成 Motion Photo，只能把两半分别交给用户。
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

    final List<_Outgoing> outgoing = <_Outgoing>[];
    int liveCount = 0;

    for (int i = 0; i < queue.length; i++) {
      final MediaImage image = queue[i];
      final String suffix = queue.length > 1 ? '_${i + 1}' : '';

      final String? url = _normalize(image.primaryUrl);
      if (url != null) {
        outgoing.add(
          _Outgoing(
            url,
            fitFileName('$stem$suffix', _imageExtension(url)),
            'image/jpeg',
          ),
        );
      }

      if (separateLive && image.isLive) {
        final String? live = _normalize(image.liveVideo?.primaryUrl);
        if (live != null) {
          outgoing.add(
            _Outgoing(live, fitFileName('$stem${suffix}_live', '.mp4'), 'video/mp4'),
          );
          liveCount += 1;
        }
      }
    }

    if (outgoing.isEmpty) {
      return const Err(AppError('没有可下载的图片'));
    }
    final _Delivery delivery = await _deliver(outgoing, stem);
    if (!delivery.ok) {
      return Err(AppError(delivery.error ?? '浏览器拒绝了下载请求'));
    }

    onProgress?.call(const DownloadProgress(fraction: 1));
    onSaved?.call(delivery.saved - liveCount, liveCount);
    onSavedFiles?.call(
      outgoing
          .map((item) => SavedMediaFile(name: item.name, mime: item.mime))
          .toList(),
    );

    if (delivery.saved <= 1) {
      return const Ok('已交给浏览器下载');
    }
    final String failed = delivery.skipped > 0
        ? '，${delivery.skipped} 个失败（详见包内 _skipped.txt）'
        : '';
    return Ok('已打包 ${delivery.saved} 个文件$failed');
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

  /// 单文件走 `/dl`，多文件走 `/api/bundle`。
  Future<_Delivery> _deliver(List<_Outgoing> files, String name) async {
    if (files.isEmpty) {
      return const _Delivery.error('没有可下载的文件');
    }
    if (files.length == 1) {
      final _Outgoing only = files.first;
      final bool ok = await _open(only.url, only.name);
      return ok
          ? const _Delivery(ok: true, saved: 1)
          : const _Delivery.error('浏览器拒绝了下载请求');
    }
    return _submitBundle(files, name);
  }

  /// 先 POST 打包拿结果，再用隐藏 iframe 触发 GET 下载。
  ///
  /// 分两步是为了能拿到失败清单：直接表单提交的话，500 会被塞进 iframe，
  /// 用户只看到「已打包」却什么都没收到。
  Future<_Delivery> _submitBundle(List<_Outgoing> files, String name) async {
    final String zipName = _zipName(name);
    try {
      final Response<dynamic> response = await _dio.post<dynamic>(
        '/api/bundle',
        data: <String, Object>{
          'name': zipName,
          'files': files
              .map((item) => <String, String>{'u': item.url, 'n': item.name})
              .toList(),
        },
      );

      if (response.statusCode != 200) {
        return _Delivery.error(_errorText(response.data));
      }
      final dynamic data = response.data;
      if (data is! Map) {
        return const _Delivery.error('打包结果格式异常');
      }
      final String token = (data['token'] ?? '').toString();
      if (token.isEmpty) {
        return const _Delivery.error('打包编号缺失');
      }

      final int saved = data['saved'] is num
          ? (data['saved'] as num).toInt()
          : files.length;
      final int skipped = data['skipped'] is List
          ? (data['skipped'] as List).length
          : 0;

      // 响应带 attachment，iframe 里不会跳页，浏览器直接落文件。
      final web.HTMLIFrameElement frame = _ensureFrame();
      frame.src = '/api/bundle/$token?n=${Uri.encodeComponent(zipName)}';

      return _Delivery(ok: true, saved: saved, skipped: skipped);
    } catch (error) {
      return _Delivery.error('打包失败：$error');
    }
  }

  String _errorText(dynamic body) {
    if (body is Map) {
      final String detail = (body['detail'] ?? '').toString().trim();
      if (detail.isNotEmpty) {
        return detail;
      }
    }
    return '打包失败，请稍后再试';
  }

  web.HTMLIFrameElement _ensureFrame() {
    const String frameId = 'clipkeep_bundle_frame';
    final web.Element? existing = web.document.getElementById(frameId);
    if (existing != null) {
      return existing as web.HTMLIFrameElement;
    }
    final web.HTMLIFrameElement frame =
        web.document.createElement('iframe') as web.HTMLIFrameElement;
    frame.id = frameId;
    frame.name = frameId;
    frame.style.display = 'none';
    web.document.body?.append(frame);
    return frame;
  }

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

  String _zipName(String raw) {
    final String cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return cleaned.isEmpty ? 'ClipKeep' : cleaned;
  }

  String _fileName(
    String? stem,
    String extension, {
    required String fallback,
  }) {
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

class _Outgoing {
  const _Outgoing(this.url, this.name, this.mime);

  final String url;
  final String name;
  final String mime;
}

/// 一次交付的结果：单文件时只有 ok，打包时带成功/失败数。
class _Delivery {
  const _Delivery({required this.ok, this.saved = 0, this.skipped = 0})
    : error = null;

  const _Delivery.error(this.error)
    : ok = false,
      saved = 0,
      skipped = 0;

  final bool ok;
  final int saved;
  final int skipped;
  final String? error;
}
