// 来源与许可声明
// ---------------------------------------------------------------------------
// 本文件的 B 站接口调用与 WBI 签名逻辑参考/移植自 PiliPlus：
//   PiliPlus - https://github.com/bggRGjQaUbCoE/PiliPlus （GPL-3.0-or-later）
//   涉及参考文件：lib/utils/wbi_sign.dart、lib/http/video.dart、lib/http/api.dart
// WBI 签名算法与 mixin key 置换表出自 bilibili-API-collect：
//   https://github.com/SocialSisterYi/bilibili-API-collect （CC-BY-NC 4.0）
// 本文件由 clipkeep 在 PiliPlus 实现基础上改写（移除 hive/http2/grpc 等重依赖）。
// 分发本文件须遵守 GPL-3.0-or-later，并保留本声明与相关许可证文本。
// ---------------------------------------------------------------------------
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../viewmodels/parsed_source.dart';

/// 解析失败，消息可直接展示给用户。
class BiliResolveException implements Exception {
  const BiliResolveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 纯 Dart 的哔哩哔哩解析器。
///
/// 参考第三方 Flutter 客户端 PiliPlus 的 API 实现：用 `/x/web-interface/wbi/view`
/// 取视频信息与分 P，用 `/x/player/wbi/playurl` 取 DASH 音视频流，两者都需要
/// WBI 签名（w_rid + wts）。原先由 Rust 侧 libbdl_ffi.so 完成的工作在此以 Dart 实现，
/// 因而无需再打包原生库。
///
/// 只依赖 Dio 与 crypto，不引入 PiliPlus 的 storage/grpc 等重依赖。
class BilibiliResolver {
  BilibiliResolver({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: const <String, String>{
                'user-agent': _userAgent,
                'referer': 'https://www.bilibili.com/',
                'accept': 'application/json, text/plain, */*',
              },
            ),
          );

  // 网页 API 用桌面 Chrome UA：B 站 upos CDN 会校验 UA，移动端 UA 对签名媒体地址会返回 403。
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  // 媒体下载专用 UA：对齐 PiliPlus 的 DownloadHttp.userAgent，CDN 接受度更好。
  static const String _downloadUserAgent = 'Bilibili Freedoooooom/MarkII';

  static const String _navUrl = 'https://api.bilibili.com/x/web-interface/nav';
  static const String _viewUrl =
      'https://api.bilibili.com/x/web-interface/wbi/view';
  static const String _playUrlUrl =
      'https://api.bilibili.com/x/player/wbi/playurl';

  static const List<int> _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static final RegExp _bvPattern = RegExp(
    r'BV[0-9A-Za-z]{10}',
    caseSensitive: false,
  );
  static final RegExp _avPattern = RegExp(
    r'(?:^|[^0-9A-Za-z_])av(\d+)',
    caseSensitive: false,
  );
  static final RegExp _chrFilter = RegExp(r"[!'()*]");
  static final Random _random = Random();

  final Dio _dio;

  String? _mixinKey;
  DateTime? _mixinKeyAt;

  // playurl 请求串行化并保持最小间隔，避免快速切 P/重试触发风控。
  static Future<void> _playUrlGate = Future<void>.value();
  static DateTime _lastPlayUrlAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _playUrlMinGap = Duration(milliseconds: 800);

  Future<T> _withPlayUrlGate<T>(Future<T> Function() action) async {
    final Completer<void> release = Completer<void>();
    final Future<void> previous = _playUrlGate;
    _playUrlGate = release.future;
    await previous;
    final Duration elapsed = DateTime.now().difference(_lastPlayUrlAt);
    if (elapsed < _playUrlMinGap) {
      await Future<void>.delayed(_playUrlMinGap - elapsed);
    }
    try {
      return await action();
    } finally {
      _lastPlayUrlAt = DateTime.now();
      release.complete();
    }
  }

  int _requestedPage(String input) {
    final Uri? uri = Uri.tryParse(input);
    return int.tryParse(uri?.queryParameters['p'] ?? '') ?? 1;
  }

  /// 把归一化后的输入（BV/AV 号或含 BV 的链接）解析为 [ParsedSource]。
  Future<ParsedSource> resolve(String input, {String? cookie}) async {
    final ({String? bvid, int? aid}) ids = _extractIds(input);
    if (ids.bvid == null && ids.aid == null) {
      throw const BiliResolveException('无法识别的哔哩哔哩链接或 ID');
    }

    final Map<String, dynamic> detail = await _getJson(
      _viewUrl,
      params: <String, Object>{
        if (ids.bvid != null) 'bvid': ids.bvid!,
        if (ids.bvid == null) 'aid': ids.aid!,
      },
      cookie: cookie,
      needWbi: true,
    );

    final String? bvid = ids.bvid ?? (detail['bvid'] as String?);
    final int? aid = ids.aid ?? (detail['aid'] as num?)?.toInt();
    final Map<String, dynamic>? owner = (detail['owner'] as Map?)
        ?.cast<String, dynamic>();

    final List<Map<String, dynamic>> pages = _pagesOf(detail);
    final int selectedPage = pages.isEmpty
        ? 0
        : (_requestedPage(input).clamp(1, pages.length) - 1);

    final List<MediaPart> parts = <MediaPart>[];
    for (int i = 0; i < pages.length; i++) {
      final Map<String, dynamic> page = pages[i];
      final int? cid = (page['cid'] as num?)?.toInt();
      // 只给当前选中的 P 拉流；切换分 P 时再按需请求，避免一次性打满 playurl。
      List<MediaStream> streams = const <MediaStream>[];
      if (i == selectedPage && cid != null) {
        streams = await _fetchStreams(
          bvid: bvid,
          aid: aid,
          cid: cid,
          cookie: cookie,
        );
      }
      parts.add(
        MediaPart(
          id: '${bvid ?? aid}-$cid',
          title:
              (page['part'] as String?) ?? (detail['title'] as String?) ?? '',
          durationSeconds: (page['duration'] as num?)?.toInt(),
          streams: streams,
        ),
      );
    }

    final int? pubdate = (detail['pubdate'] as num?)?.toInt();
    final Map<String, dynamic>? stat = (detail['stat'] as Map?)
        ?.cast<String, dynamic>();
    final String? baseUrl = bvid != null
        ? 'https://www.bilibili.com/video/$bvid'
        : (aid != null ? 'https://www.bilibili.com/video/av$aid' : null);
    final String? sourceUrl = baseUrl == null
        ? null
        : (pages.length > 1 ? '$baseUrl?p=${selectedPage + 1}' : baseUrl);
    return ParsedSource(
      title: (detail['title'] as String?) ?? '未知标题',
      author: (owner?['name'] as String?) ?? '',
      coverUrl: detail['pic'] as String?,
      publishDate: pubdate == null ? null : _formatDate(pubdate),
      likeCount: (stat?['like'] as num?)?.toInt(),
      ownerMid: (owner?['mid'] as num?)?.toInt(),
      authorAvatarUrl: owner?['face'] as String?,
      sourceUrl: sourceUrl,
      initialPartIndex: selectedPage,
      parts: parts,
    );
  }

  List<Map<String, dynamic>> _pagesOf(Map<String, dynamic> detail) {
    final List<dynamic>? rawPages = detail['pages'] as List?;
    if (rawPages != null && rawPages.isNotEmpty) {
      return rawPages
          .map((dynamic e) => (e as Map).cast<String, dynamic>())
          .toList();
    }
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'cid': detail['cid'],
        'part': detail['title'],
        'duration': detail['duration'],
      },
    ];
  }

  /// 按分段 id（形如 "BVxxx-12345" 或 "170001-12345"）重新获取最新流地址，
  /// 用于下载失败/重试时刷新过期的签名 URL。
  Future<List<MediaStream>> fetchStreamsForPart(
    String partId, {
    String? cookie,
  }) async {
    final int idx = partId.lastIndexOf('-');
    if (idx <= 0) {
      throw const BiliResolveException('无法识别的分段地址');
    }
    final String head = partId.substring(0, idx);
    final int? cid = int.tryParse(partId.substring(idx + 1));
    if (cid == null) {
      throw const BiliResolveException('无法识别的分段地址');
    }
    String? bvid;
    int? aid;
    if (head.startsWith('BV')) {
      bvid = head;
    } else {
      aid = int.tryParse(head);
    }
    if (bvid == null && aid == null) {
      throw const BiliResolveException('无法识别的分段地址');
    }
    return _fetchStreams(bvid: bvid, aid: aid, cid: cid, cookie: cookie);
  }

  Future<List<MediaStream>> _fetchStreams({
    String? bvid,
    int? aid,
    required int cid,
    String? cookie,
  }) {
    return _withPlayUrlGate(() async {
      try {
        return await _fetchStreamsOnce(
          bvid: bvid,
          aid: aid,
          cid: cid,
          cookie: cookie,
        );
      } on DioException catch (e) {
        final int? code = e.response?.statusCode;
        if (code == 412 || code == 429) {
          // 风控/限流：冷却后只重试一次。
          await Future<void>.delayed(const Duration(seconds: 3));
          return _fetchStreamsOnce(
            bvid: bvid,
            aid: aid,
            cid: cid,
            cookie: cookie,
          );
        }
        rethrow;
      }
    });
  }

  Future<List<MediaStream>> _fetchStreamsOnce({
    String? bvid,
    int? aid,
    required int cid,
    String? cookie,
  }) async {
    final Map<String, dynamic> data = await _getJson(
      _playUrlUrl,
      params: <String, Object>{
        'bvid': ?bvid,
        'avid': ?aid,
        'cid': cid,
        'qn': 127,
        // 4048 = 请求 DASH + 杜比 + 8K + AV1 等全部格式。
        'fnval': 4048,
        'fnver': 0,
        'fourk': 1,
        'web_location': 1315873,
        // 以下为网页端风控参数，缺省会更容易触发 -352。
        'dm_img_list': '[]',
        'dm_img_str': _randomBase64(16, 64),
        'dm_cover_img_str': _randomBase64(32, 128),
        'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
        // 不再使用 try_look：那是「未登录试看高清」通道，返回的 720P/1080P 是试看流，
        // 整段下载会被 CDN 403；且会让未登录也显示 480P 以上画质。
        // 未登录只取服务端正常允许的画质，需要高清请登录（带 cookie）。
      },
      cookie: cookie,
      needWbi: true,
    );

    final Map<String, dynamic>? dash = (data['dash'] as Map?)
        ?.cast<String, dynamic>();
    if (dash == null) {
      throw const BiliResolveException('该视频没有可用的 DASH 流（可能需要登录）');
    }

    final List<MediaStream> streams = <MediaStream>[];
    for (final dynamic video in (dash['video'] as List?) ?? const <dynamic>[]) {
      streams.add(_toStream((video as Map).cast<String, dynamic>(), 'video'));
    }
    for (final Map<String, dynamic> audio in _audioItems(dash)) {
      streams.add(_toStream(audio, 'audio'));
    }
    return streams;
  }

  /// 汇总普通音轨、无损 FLAC 与杜比音轨。
  List<Map<String, dynamic>> _audioItems(Map<String, dynamic> dash) {
    final List<Map<String, dynamic>> audios = <Map<String, dynamic>>[];
    final dynamic flac = (dash['flac'] as Map?)?['audio'];
    if (flac is Map) {
      audios.add(flac.cast<String, dynamic>());
    }
    final dynamic dolby = (dash['dolby'] as Map?)?['audio'];
    if (dolby is List) {
      for (final dynamic item in dolby) {
        if (item is Map) {
          audios.add(item.cast<String, dynamic>());
        }
      }
    }
    for (final dynamic item in (dash['audio'] as List?) ?? const <dynamic>[]) {
      if (item is Map) {
        audios.add(item.cast<String, dynamic>());
      }
    }
    return audios;
  }

  MediaStream _toStream(Map<String, dynamic> item, String kind) {
    final List<String> urls = <String>[];
    final dynamic base = item['baseUrl'] ?? item['base_url'];
    if (base is String && base.isNotEmpty) {
      urls.add(base);
    }
    final dynamic backups = item['backupUrl'] ?? item['backup_url'];
    if (backups is List) {
      for (final dynamic url in backups) {
        if (url is String && url.isNotEmpty && !urls.contains(url)) {
          urls.add(url);
        }
      }
    }
    return MediaStream(
      kind: kind,
      quality: (item['id'] as num?)?.toInt() ?? 0,
      codec: _codecName(
        (item['codecid'] as num?)?.toInt(),
        item['codecs'] as String?,
      ),
      urls: urls,
      headers: const <String, String>{
        'referer': 'https://www.bilibili.com/',
        'user-agent': _downloadUserAgent,
      },
      bandwidth: ((item['bandwidth'] ?? item['bandWidth']) as num?)?.toInt(),
    );
  }

  String _codecName(int? codecid, String? codecs) {
    switch (codecid) {
      case 7:
        return 'avc';
      case 12:
        return 'hevc';
      case 13:
        return 'av1';
    }
    final String s = (codecs ?? '').toLowerCase();
    if (s.contains('avc1') || s.startsWith('avc')) {
      return 'avc';
    }
    if (s.contains('hev') || s.contains('hvc') || s.contains('h265')) {
      return 'hevc';
    }
    if (s.contains('av01') || s.startsWith('av1')) {
      return 'av1';
    }
    return '';
  }

  ({String? bvid, int? aid}) _extractIds(String input) {
    final RegExpMatch? bv = _bvPattern.firstMatch(input);
    if (bv != null) {
      return (
        bvid: bv.group(0)!.replaceFirst(RegExp(r'^[Bb][Vv]'), 'BV'),
        aid: null,
      );
    }
    final RegExpMatch? av = _avPattern.firstMatch(input.trim());
    if (av != null) {
      return (bvid: null, aid: int.tryParse(av.group(1)!));
    }
    return (bvid: null, aid: null);
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required Map<String, Object> params,
    String? cookie,
    bool needWbi = false,
    bool retried = false,
  }) async {
    final Map<String, Object> query = needWbi
        ? await _sign(params)
        : Map<String, Object>.from(params);
    final Response<dynamic> res = await _dio.get<dynamic>(
      url,
      queryParameters: query,
      options: Options(
        headers: <String, String>{
          if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
        },
      ),
    );
    final dynamic body = res.data;
    if (body is! Map) {
      throw const BiliResolveException('哔哩哔哩接口返回格式异常');
    }
    final int? code = (body['code'] as num?)?.toInt();
    if (code == 0) {
      final dynamic data = body['data'];
      if (data is! Map) {
        throw const BiliResolveException('哔哩哔哩接口数据为空');
      }
      return data.cast<String, dynamic>();
    }
    // 签名过期时刷新密钥重试一次。
    if (!retried && (code == -403 || code == -352) && needWbi) {
      _mixinKey = null;
      _mixinKeyAt = null;
      return _getJson(
        url,
        params: params,
        cookie: cookie,
        needWbi: needWbi,
        retried: true,
      );
    }
    throw BiliResolveException('哔哩哔哩接口错误($code)：${body['message'] ?? '未知错误'}');
  }

  Future<Map<String, Object>> _sign(Map<String, Object> params) async {
    final String mixinKey = await _getMixinKey();
    final Map<String, Object> signed = Map<String, Object>.from(params);
    signed['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final List<String> keys = signed.keys.toList()..sort();
    final String query = keys
        .map(
          (String key) =>
              '${Uri.encodeComponent(key)}=${Uri.encodeComponent(signed[key].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    signed['w_rid'] = md5.convert(utf8.encode(query + mixinKey)).toString();
    return signed;
  }

  Future<String> _getMixinKey() async {
    final DateTime now = DateTime.now();
    final DateTime? at = _mixinKeyAt;
    final String? cached = _mixinKey;
    if (cached != null &&
        at != null &&
        now.difference(at) < const Duration(hours: 6)) {
      return cached;
    }
    // nav 未登录会返回 code=-101，但 data.wbi_img 仍可用，故直接读 data。
    final Response<dynamic> res = await _dio.get<dynamic>(_navUrl);
    final dynamic body = res.data;
    if (body is Map) {
      final dynamic data = body['data'];
      if (data is Map) {
        final dynamic wbi = data['wbi_img'];
        if (wbi is Map) {
          final String img = _fileStem(wbi['img_url']);
          final String sub = _fileStem(wbi['sub_url']);
          if (img.isNotEmpty && sub.isNotEmpty) {
            final String mixin = _shuffle(img + sub);
            _mixinKey = mixin;
            _mixinKeyAt = now;
            return mixin;
          }
        }
      }
    }
    throw const BiliResolveException('获取哔哩哔哩 WBI 签名密钥失败');
  }

  String _shuffle(String original) {
    final StringBuffer buffer = StringBuffer();
    for (final int index in _mixinKeyEncTab) {
      if (index < original.length) {
        buffer.writeCharCode(original.codeUnitAt(index));
      }
    }
    return buffer.toString();
  }

  String _fileStem(dynamic url) {
    if (url is! String) {
      return '';
    }
    final int slash = url.lastIndexOf('/');
    final String name = slash >= 0 ? url.substring(slash + 1) : url;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _randomBase64(int minLength, int maxLength) {
    final int length = minLength + _random.nextInt(maxLength - minLength + 1);
    // 字节保持 0x26~0x7E，避免 base64 前出现 '%' 干扰签名。
    final List<int> bytes = List<int>.generate(
      length,
      (_) => 0x26 + _random.nextInt(0x59),
    );
    final String encoded = base64.encode(bytes);
    return encoded.substring(0, encoded.length - 2);
  }

  String _formatDate(int epochSeconds) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    ).add(const Duration(hours: 8));
    final String y = date.year.toString().padLeft(4, '0');
    final String m = date.month.toString().padLeft(2, '0');
    final String d = date.day.toString().padLeft(2, '0');
    final String hh = date.hour.toString().padLeft(2, '0');
    final String mm = date.minute.toString().padLeft(2, '0');
    final String ss = date.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }
}
