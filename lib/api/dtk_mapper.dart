import 'dart:math' as math;

import '../viewmodels/parsed_source.dart';

/// DTK 归一化记录无法转成当前下载模型时抛出（如图文/图集）。
class DtkUnsupported implements Exception {
  DtkUnsupported(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 抖音直链请求头（对齐 douyinDL 脚本：桌面 UA + Referer/Origin + Sec-Fetch）。
const Map<String, String> _douyinHeaders = <String, String>{
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'accept': '*/*',
  'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
  'referer': 'https://www.douyin.com/',
  'origin': 'https://www.douyin.com',
  'sec-fetch-dest': 'video',
  'sec-fetch-mode': 'cors',
  'sec-fetch-site': 'cross-site',
};

/// 把 DTK 的 Content JSON 映射成 App 的 [ParsedSource]（当前仅视频）。
ParsedSource mapDtkContent(Map<String, dynamic> content) {
  final String kind = (content['kind'] ?? '').toString().toLowerCase();
  final Map<String, dynamic> media = _asMap(content['media']);
  final Map<String, dynamic> author = _asMap(content['author']);

  final String rawTitle = content['title']?.toString().trim() ?? '';
  final String title = rawTitle.isNotEmpty
      ? rawTitle
      : (content['description']?.toString() ?? '抖音作品');
  final String authorName = author['nickname']?.toString() ?? '';
  final String? avatar = _imageUrl(_asMapOrNull(author['avatar']));
  final String? cover = _firstImageUrl(media['covers']);
  final String webUrl = content['web_url']?.toString() ?? '';
  final int durationMs = _asInt(content['duration_ms']);
  final String? publishDate = _formatDate(content['created_at']);

  if (kind.isNotEmpty && kind != 'video') {
    throw DtkUnsupported('暂不支持图文/图集作品，目前仅支持视频');
  }

  final List<MediaStream> streams = _buildStreams(content, media);
  if (streams.isEmpty) {
    throw DtkUnsupported('该作品没有可下载的视频流');
  }
  final MediaStream primary = streams.first;
  final int width = primary.width ?? 0;
  final int height = primary.height ?? 0;

  final String partId = webUrl.isNotEmpty
      ? webUrl
      : (content['content_id']?.toString() ?? '');
  return ParsedSource(
    title: title,
    author: authorName,
    coverUrl: cover,
    publishDate: publishDate,
    authorAvatarUrl: avatar,
    platform: content['platform']?.toString() ?? 'douyin',
    videoWidth: width,
    videoHeight: height,
    parts: <MediaPart>[
      MediaPart(
        id: partId,
        title: title,
        durationSeconds: durationMs > 0 ? (durationMs / 1000).round() : null,
        streams: streams,
      ),
    ],
  );
}

/// 多画质来源优先级：归一化 media.streams（数量最全）> 原始 bit_rate > media.video。
List<MediaStream> _buildStreams(
  Map<String, dynamic> content,
  Map<String, dynamic> media,
) {
  final Map<String, dynamic> raw = _asMap(content['raw']);
  final Map<String, dynamic> rawVideo = _asMap(raw['video']);
  final Map<String, int> fpsByKey = _fpsMap(rawVideo);
  final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];

  void addEntry(
    Map<String, dynamic> node, {
    int? forcedFps,
    int? forcedSize,
    bool requireMeta = false,
  }) {
    final List<String> urls = _playUrls(node);
    if (urls.isEmpty) {
      return;
    }
    final int w = _asInt(node['width']);
    final int h = _asInt(node['height']);
    final int shortSide = _shortSide(w, h);
    if (shortSide <= 0) {
      return;
    }
    final int? bitrate = _asIntOrNull(node['bitrate'] ?? node['bit_rate']);
    final int? size =
        forcedSize ?? _asIntOrNull(node['size_bytes'] ?? node['data_size']);
    if (requireMeta && bitrate == null && size == null) {
      return;
    }
    final int? fps = forcedFps ?? fpsByKey[_streamKey(w, h, bitrate)];
    entries.add(<String, dynamic>{
      'urls': urls,
      'w': w,
      'h': h,
      'short': shortSide,
      'bitrate': bitrate,
      'size': size,
      'fps': fps,
    });
  }

  final dynamic normalized = media['streams'];
  if (normalized is List) {
    for (final dynamic item in normalized) {
      final Map<String, dynamic>? node = _asMapOrNull(item);
      if (node != null) {
        addEntry(node, requireMeta: true);
      }
    }
  }
  if (entries.isEmpty) {
    final dynamic bitRates = rawVideo['bit_rate'];
    if (bitRates is List) {
      for (final dynamic item in bitRates) {
        final Map<String, dynamic>? br = _asMapOrNull(item);
        if (br == null) {
          continue;
        }
        final Map<String, dynamic> playAddr = _asMap(br['play_addr']);
        addEntry(
          playAddr,
          forcedFps: _asInt(br['FPS'] ?? br['fps']),
          forcedSize: _asIntOrNull(playAddr['data_size']),
        );
      }
    }
  }
  if (entries.isEmpty) {
    final Map<String, dynamic>? video = _asMapOrNull(media['video']);
    if (video != null) {
      addEntry(video);
    }
  }

  entries.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
    final int byShort = (b['short'] as int).compareTo(a['short'] as int);
    if (byShort != 0) {
      return byShort;
    }
    final int ab = (a['bitrate'] as int?) ?? 0;
    final int bb = (b['bitrate'] as int?) ?? 0;
    return bb.compareTo(ab);
  });

  final List<MediaStream> out = <MediaStream>[];
  final Map<int, int> rankByShort = <int, int>{};
  final Set<String> seen = <String>{};
  for (final Map<String, dynamic> e in entries) {
    final String key = '${e['short']}|${e['bitrate']}|${e['size']}|${e['fps']}';
    if (!seen.add(key)) {
      continue;
    }
    final int shortSide = e['short'] as int;
    final int rank = rankByShort[shortSide] ?? 0;
    rankByShort[shortSide] = rank + 1;
    out.add(
      MediaStream(
        kind: 'video',
        quality: shortSide * 1000 + (999 - rank),
        codec: 'avc',
        urls: e['urls'] as List<String>,
        headers: _douyinHeaders,
        bandwidth: e['bitrate'] as int?,
        width: e['w'] as int,
        height: e['h'] as int,
        fps: e['fps'] as int?,
        bitrate: e['bitrate'] as int?,
        sizeBytes: e['size'] as int?,
        resolutionLabel: _resolutionLabel(shortSide),
      ),
    );
  }
  return out;
}

Map<String, int> _fpsMap(Map<String, dynamic> rawVideo) {
  final Map<String, int> map = <String, int>{};
  final dynamic list = rawVideo['bit_rate'];
  if (list is List) {
    for (final dynamic item in list) {
      final Map<String, dynamic>? br = _asMapOrNull(item);
      if (br == null) {
        continue;
      }
      final Map<String, dynamic> playAddr = _asMap(br['play_addr']);
      final int w = _asInt(playAddr['width'] ?? br['width']);
      final int h = _asInt(playAddr['height'] ?? br['height']);
      final int? bitrate = _asIntOrNull(br['bit_rate']);
      final int fps = _asInt(br['FPS'] ?? br['fps']);
      if (fps > 0) {
        map[_streamKey(w, h, bitrate)] = fps;
      }
    }
  }
  return map;
}

String _streamKey(int width, int height, int? bitrate) =>
    '$width×$height:${bitrate ?? 0}';

int _shortSide(int width, int height) {
  if (width > 0 && height > 0) {
    return math.min(width, height);
  }
  return height > 0 ? height : (width > 0 ? width : 0);
}

String _resolutionLabel(int shortSide) {
  if (shortSide >= 2160) {
    return '4K';
  }
  if (shortSide >= 1440) {
    return '2K';
  }
  return '$shortSide'
      'P';
}

/// 只取可用的 www.douyin.com/aweme/v1/play 直链（douyinvod 镜像有防盗链）。
List<String> _playUrls(Map<String, dynamic> node) {
  final List<String> all = _streamUrls(node);
  final List<String> preferred = all
      .where((String u) => u.startsWith('https://www.douyin.com'))
      .toList();
  return preferred.isNotEmpty ? preferred : all;
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return <String, dynamic>{};
}

Map<String, dynamic>? _asMapOrNull(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}

int _asInt(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _asIntOrNull(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

String? _imageUrl(Map<String, dynamic>? image) {
  if (image == null) {
    return null;
  }
  final String url = image['url']?.toString() ?? '';
  if (url.isNotEmpty) {
    return url;
  }
  return _firstFromList(image['urls']);
}

String? _firstImageUrl(dynamic covers) {
  if (covers is List) {
    for (final dynamic item in covers) {
      final String? url = _imageUrl(_asMapOrNull(item));
      if (url != null && url.isNotEmpty) {
        return url;
      }
    }
  }
  return null;
}

String? _firstFromList(dynamic raw) {
  if (raw is List) {
    for (final dynamic item in raw) {
      final String value = item?.toString() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
  }
  return null;
}

List<String> _streamUrls(Map<String, dynamic> item) {
  final List<String> out = <String>[];
  final String first = item['url']?.toString() ?? '';
  if (first.isNotEmpty) {
    out.add(first);
  }
  final dynamic list = item['urls'];
  if (list is List) {
    for (final dynamic value in list) {
      final String url = value?.toString() ?? '';
      if (url.isNotEmpty && !out.contains(url)) {
        out.add(url);
      }
    }
  }
  return out;
}

String? _formatDate(dynamic value) {
  if (value == null) {
    return null;
  }
  final DateTime? parsed = DateTime.tryParse(value.toString());
  if (parsed == null) {
    return null;
  }
  final DateTime local = parsed.toLocal();
  final String y = local.year.toString().padLeft(4, '0');
  final String m = local.month.toString().padLeft(2, '0');
  final String d = local.day.toString().padLeft(2, '0');
  final String hh = local.hour.toString().padLeft(2, '0');
  final String mi = local.minute.toString().padLeft(2, '0');
  final String ss = local.second.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mi:$ss';
}
