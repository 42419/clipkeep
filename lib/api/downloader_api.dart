import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/media_downloader.dart';
import '../utils/result.dart';
import '../utils/image_headers.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'dtk_client.dart';

/// 数据接口层：封装抖音解析与媒体下载，供 Store 调用。
class DownloaderApi {
  DownloaderApi({MediaDownloader? mediaDownloader, this.dtkConfig})
    : _media = mediaDownloader ?? MediaDownloader();

  final MediaDownloader _media;

  /// 读取抖音解析服务配置（由 Store 注入，指向 SettingsStore）。
  final DtkConfig Function()? dtkConfig;

  final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: const <String, String>{
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124 Safari/537.36',
        'accept': 'application/json, text/plain, */*',
      },
    ),
  );

  Future<Result<ParsedSource>> parse(String input) async {
    try {
      final String normalized = _normalizeInput(input);
      if (!_isDouyinLink(normalized)) {
        return const Err(AppError('目前仅支持抖音链接'));
      }
      final DtkConfig? config = dtkConfig?.call();
      if (config == null || !config.isConfigured) {
        return const Err(AppError('请先在设置页填写抖音解析服务地址与 API Key'));
      }
      // 传归一化结果：裸 aweme_id 会被转成抖音视频页，分享文案则提取出 URL。
      return await DtkClient(config).parse(normalized);
    } on DioException catch (e) {
      final int? code = e.response?.statusCode;
      if (code == 412 || code == 429) {
        return Err(AppError('请求过于频繁（HTTP $code），请稍后重试', cause: e));
      }
      if (code != null) {
        return Err(AppError('网络请求失败（HTTP $code）', cause: e));
      }
      return Err(AppError('网络连接失败：${e.type.name}', cause: e));
    } catch (e) {
      return Err(AppError('解析失败：${e.runtimeType}', cause: e));
    }
  }

  static bool _isDouyinLink(String value) {
    final String lower = value.toLowerCase();
    return lower.contains('douyin.com') || lower.contains('iesdouyin.com');
  }

  /// 把封面缓存到本地 App 私有目录，返回本地路径（失败返回 null）。
  Future<String?> cacheCover(String? coverUrl, String id) async {
    final String? url = _normalizeImageUrl(coverUrl);
    if (url == null) {
      return null;
    }
    try {
      final Directory dir = await getApplicationSupportDirectory();
      final Directory covers = Directory('${dir.path}/covers');
      if (!await covers.exists()) {
        await covers.create(recursive: true);
      }
      final String path = '${covers.path}/$id.jpg';
      final File file = File(path);
      if (await file.exists() && await file.length() > 0) {
        // 缓存里可能混入 HTML/403 错误页，必须校验图片头后再复用。
        if (_looksLikeImage(await file.readAsBytes())) {
          return path;
        }
        await file.delete();
      }
      final Response<List<int>> res = await _http.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: imageHeadersFor(url),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final List<int>? data = res.data;
      if (data == null || data.isEmpty || !_looksLikeImage(data)) {
        return null;
      }
      final File temp = File('$path.tmp');
      await temp.writeAsBytes(data, flush: true);
      await temp.rename(path);
      return path;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) {
      return false;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return true;
    }
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // GIF
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return true;
    }
    // WebP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      final String brand = String.fromCharCodes(bytes.sublist(8, 12));
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
  }

  String? _normalizeImageUrl(String? raw) {
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

  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
  static final RegExp _trailingPunctuation = RegExp(r'[),.;!?，。；！？、）】》」』]+$');

  /// 把用户输入归一化为抖音链接或裸 aweme_id。
  String _normalizeInput(String raw) {
    final String text = raw.trim();
    final RegExpMatch? match = _urlPattern.firstMatch(text);
    if (match == null) {
      // 纯数字按抖音作品 ID 处理（aweme_id 通常 15 位以上）。
      final RegExpMatch? aweme = RegExp(r'^\d{15,}$').firstMatch(text);
      if (aweme != null) {
        return 'https://www.douyin.com/video/${aweme.group(0)}';
      }
      return text;
    }
    return match.group(0)!.replaceAll(_trailingPunctuation, '');
  }

  /// 删除某个任务的临时下载产物（源流/分片/合并结果）。
  Future<void> cleanup(String downloadId) => _media.cleanupTemp(downloadId);

  Future<void> cleanupOrphans(Set<String> keepIds) =>
      _media.cleanupOrphans(keepIds);

  Future<int?> probeSelectionTotal(MediaPart part, {int? videoQuality}) =>
      _media.probeSelectionTotal(part, videoQuality: videoQuality);

  Future<Result<String>> saveImages(
    List<MediaImage> images, {
    int? onlyIndex,
    String? downloadId,
    String? fileStem,
    bool separateLive = false,
    void Function(DownloadProgress progress)? onProgress,
    void Function(int savedItems, int liveItems)? onSaved,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) {
    return _media.saveImages(
      images,
      onlyIndex: onlyIndex,
      downloadId: downloadId,
      fileStem: fileStem,
      separateLive: separateLive,
      onProgress: onProgress,
      onSaved: onSaved,
      onSavedFiles: onSavedFiles,
    );
  }

  /// 手动把本地图片 + 视频合成 Motion Photo。
  Future<Result<String>> composeMotionPhoto({
    required String imagePath,
    required String videoPath,
  }) => _media.composeMotionPhoto(imagePath: imagePath, videoPath: videoPath);

  /// 应用外部目录的可用字节数。
  Future<int?> freeBytes() => _media.freeBytes();

  /// 打开/分享已保存文件。
  Future<Result<String>> openSaved(List<String> names) =>
      _media.openSaved(names);

  Future<Result<String>> shareSaved(List<String> names) =>
      _media.shareSaved(names);

  /// 缓存占用与清理。
  Future<int> cacheBytes() => _media.cacheBytes();

  Future<int> clearCache() => _media.clearCache();

  /// 把本地图片和视频分别保存。
  Future<Result<String>> saveLocalPair({
    required String imagePath,
    required String videoPath,
  }) => _media.saveLocalPair(imagePath: imagePath, videoPath: videoPath);

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
  }) {
    return _media.download(
      part,
      videoQuality: videoQuality,
      coverOnly: coverOnly,
      saveCover: saveCover,
      coverUrl: coverUrl,
      downloadId: downloadId,
      fileStem: fileStem,
      cancelToken: cancelToken,
      onProgress: onProgress,
      onSavedFiles: onSavedFiles,
    );
  }

  /// 按分段刷新最新流地址（下载失败重试时用，避免复用过期签名 URL）。
  Future<Result<List<MediaStream>>> refreshStreams(MediaPart part) async {
    final DtkConfig? config = dtkConfig?.call();
    if (config == null || !config.isConfigured) {
      return const Err(AppError('请先在设置页填写抖音解析服务地址与 API Key'));
    }
    return DtkClient(config).refreshStreams(part.id);
  }
}
