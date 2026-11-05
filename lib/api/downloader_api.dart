import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/bdl_service.dart';
import '../utils/media_downloader.dart';
import '../utils/result.dart';
import '../viewmodels/parsed_source.dart';

/// 数据接口层：封装 B 站解析与媒体下载，供 Store 调用。
class DownloaderApi {
  DownloaderApi({BdlService? bdlService, MediaDownloader? mediaDownloader})
    : _bdl = bdlService ?? const BdlService(),
      _media = mediaDownloader ?? MediaDownloader();

  final BdlService _bdl;
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

  Future<Result<ParsedSource>> parse(String input) async {
    final dir = await getApplicationSupportDirectory();
    final String normalized = await _normalizeInput(input);
    final response = await _bdl.parse(
      input: normalized,
      stateDir: dir.path,
      withStreams: true,
    );
    if (!response.ok) {
      return Err(AppError(response.error ?? '解析失败'));
    }
    final data = response.data;
    if (data == null) {
      return const Err(AppError('解析结果为空'));
    }
    try {
      return Ok(await _toParsedSource(data));
    } catch (e) {
      return Err(AppError('解析结果格式异常', cause: e));
    }
  }

  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');
  static final RegExp _bvPattern = RegExp(r'BV[0-9A-Za-z]{10}');
  static final RegExp _trailingPunctuation =
      RegExp(r'[),.;!?，。；！？、）】》」』]+$');

  /// 把用户输入归一化为 bdl 可识别形式：完整链接、含标题的分享文本、b23 短链都可。
  /// 视频链接优先提取 BV 号直接交给 bdl；其它类型保留（解析后的）完整链接。
  Future<String> _normalizeInput(String raw) async {
    final String text = raw.trim();
    final RegExpMatch? match = _urlPattern.firstMatch(text);
    if (match == null) {
      final RegExpMatch? bv = _bvPattern.firstMatch(text);
      return bv?.group(0) ?? text;
    }
    String url = match.group(0)!.replaceAll(_trailingPunctuation, '');
    final bool isShort =
        url.contains('b23.tv') || url.contains('bili2233.cn');
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

  /// 跟随 b23.tv 重定向取最终地址；失败返回 null（回退原短链，bdl 仍会尝试展开）。
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
    void Function(double progress)? onProgress,
  }) {
    return _media.download(
      part,
      videoQuality: videoQuality,
      audioOnly: audioOnly,
      coverOnly: coverOnly,
      saveCover: saveCover,
      coverUrl: coverUrl,
      onProgress: onProgress,
    );
  }

  Future<ParsedSource> _toParsedSource(Map<String, dynamic> tree) async {
    final source =
        (tree['source'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final groups = (tree['groups'] as List?) ?? const <dynamic>[];
    final items = <Map<String, dynamic>>[];
    for (final group in groups) {
      final groupMap = (group as Map).cast<String, dynamic>();
      final list = (groupMap['items'] as List?) ?? const <dynamic>[];
      for (final item in list) {
        items.add((item as Map).cast<String, dynamic>());
      }
    }
    final first = items.isNotEmpty ? items.first : <String, dynamic>{};
    final parts = <MediaPart>[];
    final rawParts = (first['parts'] as List?) ?? const <dynamic>[];
    for (final part in rawParts) {
      parts.add(_toPart((part as Map).cast<String, dynamic>()));
    }
    final int? ownerMid = (first['owner_mid'] as num?)?.toInt();
    final String? avatarUrl = await _fetchAvatar(ownerMid);
    return ParsedSource(
      title:
          (first['title'] as String?) ?? (source['title'] as String?) ?? '未知标题',
      author: (first['owner_name'] as String?) ?? '',
      coverUrl: first['cover_url'] as String?,
      publishDate: first['publish_date'] as String?,
      ownerMid: ownerMid,
      authorAvatarUrl: avatarUrl,
      parts: parts,
    );
  }

  /// 用 UP 主 mid 调 B 站 card 接口取头像；失败不影响解析。
  Future<String?> _fetchAvatar(int? mid) async {
    if (mid == null) {
      return null;
    }
    try {
      final res = await _http.get<dynamic>(
        'https://api.bilibili.com/x/web-interface/card',
        queryParameters: <String, dynamic>{'mid': mid, 'photo': 'false'},
      );
      final data = res.data as Map?;
      if (data != null && data['code'] == 0) {
        final card = (data['data'] as Map?)?['card'] as Map?;
        final face = card?['face'];
        if (face is String && face.isNotEmpty) {
          return face;
        }
      }
    } catch (_) {
      // 忽略：取头像失败时回退到图标
    }
    return null;
  }

  MediaPart _toPart(Map<String, dynamic> part) {
    final streams = <MediaStream>[];
    final rawStreams = (part['streams'] as List?) ?? const <dynamic>[];
    for (final stream in rawStreams) {
      final streamMap = (stream as Map).cast<String, dynamic>();
      final quality = (streamMap['quality'] as Map?)?.cast<String, dynamic>();
      final headers = <String, String>{};
      final rawHeaders = (streamMap['headers'] as List?) ?? const <dynamic>[];
      for (final header in rawHeaders) {
        final headerMap = (header as Map).cast<String, dynamic>();
        final name = headerMap['name'] as String?;
        final value = headerMap['value'] as String?;
        if (name != null && value != null) {
          headers[name] = value;
        }
      }
      final urls = ((streamMap['urls'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
      streams.add(
        MediaStream(
          kind: (streamMap['kind'] as String?) ?? '',
          quality: (quality?['value'] as num?)?.toInt() ?? 0,
          codec: (streamMap['codec'] as String?) ?? '',
          urls: urls,
          headers: headers,
          bandwidth: (streamMap['bandwidth'] as num?)?.toInt(),
        ),
      );
    }
    return MediaPart(
      id: (part['id'] as String?) ?? '',
      title: (part['title'] as String?) ?? '',
      durationSeconds: (part['duration_seconds'] as num?)?.toInt(),
      streams: streams,
    );
  }
}
