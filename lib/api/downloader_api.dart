import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/media_downloader.dart';
import '../utils/result.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';
import 'bilibili_resolver.dart';

/// 数据接口层：封装 B 站解析与媒体下载，供 Store 调用。
class DownloaderApi {
  DownloaderApi({BilibiliResolver? resolver, MediaDownloader? mediaDownloader})
    : _resolver = resolver ?? BilibiliResolver(),
      _media = mediaDownloader ?? MediaDownloader();

  final BilibiliResolver _resolver;
  final MediaDownloader _media;

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
      final ParsedSource source = await _resolver.resolve(
        normalized,
        cookie: cookie,
      );
      return Ok(source);
    } on BiliResolveException catch (e) {
      return Err(AppError(e.message, cause: e));
    } catch (e) {
      return Err(AppError('解析失败', cause: e));
    }
  }

  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

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
        return path;
      }
      final Response<List<int>> res = await _http.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: _imageHeaders,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final List<int>? data = res.data;
      if (data == null || data.isEmpty) {
        return null;
      }
      await file.writeAsBytes(data);
      return path;
    } catch (_) {
      return null;
    }
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
  static final RegExp _bvPattern = RegExp(r'BV[0-9A-Za-z]{10}');
  static final RegExp _trailingPunctuation = RegExp(r'[),.;!?，。；！？、）】》」』]+$');

  /// 把用户输入归一化为可解析形式：完整链接、含标题的分享文本、b23 短链都可。
  /// 视频链接优先提取 BV 号；其它类型保留（解析后的）完整链接。
  Future<String> _normalizeInput(String raw) async {
    final String text = raw.trim();
    final RegExpMatch? match = _urlPattern.firstMatch(text);
    if (match == null) {
      final RegExpMatch? bv = _bvPattern.firstMatch(text);
      return bv?.group(0) ?? text;
    }
    String url = match.group(0)!.replaceAll(_trailingPunctuation, '');
    final bool isShort = url.contains('b23.tv') || url.contains('bili2233.cn');
    if (isShort) {
      final String? resolved = await _resolveShortLink(url);
      if (resolved != null) {
        url = resolved;
      }
    }
    final RegExpMatch? bv = _bvPattern.firstMatch(url);
    if (bv != null) {
      return bv.group(0)!;
    }
    return url;
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

  Future<Result<String>> download(
    MediaPart part, {
    int? videoQuality,
    bool audioOnly = false,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    String? cookie,
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
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }
}
