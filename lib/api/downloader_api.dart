import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/media_downloader.dart';
import '../utils/result.dart';
import '../utils/image_headers.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'bilibili_resolver.dart';
import 'dtk_client.dart';

/// 数据接口层：封装 B 站解析与媒体下载，供 Store 调用。
class DownloaderApi {
  DownloaderApi({
    BilibiliResolver? resolver,
    MediaDownloader? mediaDownloader,
    this.dtkConfig,
  }) : _resolver = resolver ?? BilibiliResolver(),
       _media = mediaDownloader ?? MediaDownloader();

  final BilibiliResolver _resolver;
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
        'referer': 'https://www.bilibili.com/',
        'accept': 'application/json, text/plain, */*',
      },
    ),
  );

  Future<Result<ParsedSource>> parse(String input, {String? cookie}) async {
    try {
      final String normalized = await _normalizeInput(input);
      if (_isDtkLink(normalized)) {
        final DtkConfig? config = dtkConfig?.call();
        if (config == null || !config.isConfigured) {
          return const Err(
            AppError('当前构建未内置抖音解析服务（缺少 DTK_BASE_URL / DTK_API_KEY，需构建时注入）'),
          );
        }
        // 传归一化结果：裸 aweme_id 会被转成抖音视频页，分享文案则提取出 URL。
        return await DtkClient(config).parse(normalized);
      }
      final ParsedSource source = await _resolver.resolve(
        normalized,
        cookie: cookie,
      );
      return Ok(source);
    } on BiliResolveException catch (e) {
      return Err(AppError(e.message, cause: e));
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

  static bool _isDtkLink(String value) {
    final String lower = value.toLowerCase();
    return lower.contains('douyin.com') ||
        lower.contains('iesdouyin.com') ||
        lower.contains('tiktok.com');
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
        // 旧版本可能把 HTML/403 错误页写进缓存，必须校验图片头后再复用。
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
  static final RegExp _bvPattern = RegExp(
    r'BV[0-9A-Za-z]{10}',
    caseSensitive: false,
  );
  static final RegExp _trailingPunctuation = RegExp(r'[),.;!?，。；！？、）】》」』]+$');
  static final RegExp _alnum = RegExp(r'[0-9A-Za-z]');

  RegExpMatch? _firstBv(String text) {
    for (final RegExpMatch match in _bvPattern.allMatches(text)) {
      if (match.start == 0 || !_alnum.hasMatch(text[match.start - 1])) {
        return match;
      }
    }
    return null;
  }

  /// 把用户输入归一化为可解析形式：完整链接、含标题的分享文本、b23 短链都可。
  /// 先判平台再抽 BV：抖音长链接的随机串可能恰好匹配 BV 号，反过来会误判。
  Future<String> _normalizeInput(String raw) async {
    final String text = raw.trim();
    final RegExpMatch? match = _urlPattern.firstMatch(text);
    if (match == null) {
      final RegExpMatch? bv = _firstBv(text);
      if (bv != null) {
        return bv.group(0)!.replaceFirst(RegExp(r'^[Bb][Vv]'), 'BV');
      }
      // 纯数字按抖音作品 ID 处理（aweme_id 通常 19 位）。
      final RegExpMatch? aweme = RegExp(r'^\d{15,}$').firstMatch(text);
      if (aweme != null) {
        return 'https://www.douyin.com/video/${aweme.group(0)}';
      }
      return text;
    }
    final String url = match.group(0)!.replaceAll(_trailingPunctuation, '');
    if (_isDtkLink(url)) {
      return url;
    }
    String resolved = url;
    final bool isShort =
        resolved.contains('b23.tv') || resolved.contains('bili2233.cn');
    if (isShort) {
      final String? finalUrl = await _resolveShortLink(resolved);
      if (finalUrl != null) {
        resolved = finalUrl;
      }
    }
    final RegExpMatch? bv = _firstBv(resolved);
    if (bv != null) {
      final Uri? uri = Uri.tryParse(resolved);
      final String bvId = bv.group(0)!.replaceFirst(RegExp(r'^[Bb][Vv]'), 'BV');
      final String? page = uri?.queryParameters['p'];
      if (page == null || page.isEmpty) {
        return bvId;
      }
      return 'https://www.bilibili.com/video/$bvId?p=$page';
    }
    return resolved;
  }

  /// 跟随 b23.tv 重定向取最终地址；失败返回 null（回退原短链）。
  Future<String?> _resolveShortLink(String shortUrl) async {
    try {
      final Response<dynamic> response = await _http.get<dynamic>(
        shortUrl,
        options: Options(
          followRedirects: true,
          maxRedirects: 6,
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (int? status) => status != null && status < 500,
        ),
      );
      final String finalUrl = response.realUri.toString();
      return finalUrl.isEmpty ? null : finalUrl;
    } catch (_) {
      return null;
    }
  }

  /// 删除某个任务的临时下载产物（源流/分片/合并结果）。
  Future<void> cleanup(String downloadId) => _media.cleanupTemp(downloadId);

  Future<void> cleanupOrphans(Set<String> keepIds) =>
      _media.cleanupOrphans(keepIds);

  Future<Result<String>> saveImages(
    List<MediaImage> images, {
    int? onlyIndex,
    String? downloadId,
    void Function(DownloadProgress progress)? onProgress,
    void Function(int savedItems, int liveItems)? onSaved,
  }) {
    return _media.saveImages(
      images,
      onlyIndex: onlyIndex,
      downloadId: downloadId,
      onProgress: onProgress,
      onSaved: onSaved,
    );
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
  }) {
    return _media.download(
      part,
      videoQuality: videoQuality,
      audioOnly: audioOnly,
      coverOnly: coverOnly,
      saveCover: saveCover,
      coverUrl: coverUrl,
      cookie: cookie,
      downloadId: downloadId,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  /// 按分段刷新最新流地址（下载失败重试时用，避免复用过期签名 URL）。
  Future<Result<List<MediaStream>>> refreshStreams(
    MediaPart part, {
    String? cookie,
  }) async {
    // B 站分 P id 形如 BV...-cid / aid-cid；其余（web_url、content_id）按抖音处理。
    final bool biliPart = RegExp(
      r'^(BV[0-9A-Za-z]{10}|[0-9]+)-[0-9]+$',
      caseSensitive: false,
    ).hasMatch(part.id);
    if (!biliPart) {
      final DtkConfig? config = dtkConfig?.call();
      if (config == null || !config.isConfigured) {
        return const Err(AppError('当前构建未内置抖音解析服务'));
      }
      return DtkClient(config).refreshStreams(part.id);
    }
    try {
      final List<MediaStream> streams = await _resolver.fetchStreamsForPart(
        part.id,
        cookie: cookie,
      );
      if (streams.isEmpty) {
        return const Err(AppError('刷新下载地址失败：没有可用流'));
      }
      return Ok(streams);
    } on BiliResolveException catch (e) {
      return Err(AppError(e.message, cause: e));
    } catch (e) {
      return Err(AppError('刷新下载地址失败', cause: e));
    }
  }
}
