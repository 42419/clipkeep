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

/// 从原始响应的 video.bit_rate 枚举全部画质；没有则退回归一化单条。
List<MediaStream> _buildStreams(
  Map<String, dynamic> content,
  Map<String, dynamic> media,
) {
  final List<MediaStream> out = <MediaStream>[];
  final Map<String, dynamic> raw = _asMap(content['raw']);
  final Map<String, dynamic> rawVideo = _asMap(raw['video']);
  final dynamic bitRates = rawVideo['bit_rate'];
  final bool h265 = rawVideo['is_h265'] == true;
  if (bitRates is List && bitRates.isNotEmpty) {
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    for (final dynamic item in bitRates) {
      final Map<String, dynamic>? br = _asMapOrNull(item);
      if (br == null) {
        continue;
      }
      final Map<String, dynamic> playAddr = _asMap(br['play_addr']);
      final List<String> urls = _playUrls(playAddr);
      if (urls.isEmpty) {
        continue;
      }
      final int w = _asInt(playAddr['width'] ?? br['width']);
      final int h = _asInt(playAddr['height'] ?? br['height']);
      final int shortSide = _shortSide(w, h);
      if (shortSide <= 0) {
        continue;
      }
      entries.add(<String, dynamic>{
        'urls': urls,
        'w': w,
        'h': h,
        'short': shortSide,
        'fps': _asInt(br['FPS'] ?? br['fps']),
        'bitrate': _asIntOrNull(br['bit_rate']),
      });
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
    final Map<int, int> rankByShort = <int, int>{};
    for (final Map<String, dynamic> e in entries) {
      final int shortSide = e['short'] as int;
      final int rank = rankByShort[shortSide] ?? 0;
      rankByShort[shortSide] = rank + 1;
      out.add(
        MediaStream(
          kind: 'video',
          quality: shortSide * 1000 + (999 - rank),
          codec: h265 ? 'hevc' : 'avc',
          urls: e['urls'] as List<String>,
          headers: _douyinHeaders,
          bandwidth: e['bitrate'] as int?,
          width: e['w'] as int,
          height: e['h'] as int,
          fps: (e['fps'] as int) > 0 ? e['fps'] as int : null,
          bitrate: e['bitrate'] as int?,
          resolutionLabel: _resolutionLabel(shortSide),
        ),
      );
    }
  }
  if (out.isEmpty) {
    Map<String, dynamic>? video = _asMapOrNull(media['video']);
    if (video == null || _playUrls(video).isEmpty) {
      final dynamic list = media['streams'];
      if (list is List) {
        for (final dynamic item in list) {
          final Map<String, dynamic>? candidate = _asMapOrNull(item);
          if (candidate != null && _playUrls(candidate).isNotEmpty) {
            video = candidate;
            break;
          }
        }
      }
    }
    if (video != null) {
      final int w = _asInt(video['width']);
      final int h = _asInt(video['height']);
      final int shortSide = _shortSide(w, h);
      out.add(
        MediaStream(
          kind: 'video',
          quality: shortSide > 0 ? shortSide * 1000 : 1,
          codec: 'avc',
          urls: _playUrls(video),
          headers: _douyinHeaders,
          bandwidth: _asIntOrNull(video['bitrate']),
          width: w > 0 ? w : null,
          height: h > 0 ? h : null,
          resolutionLabel: shortSide > 0 ? _resolutionLabel(shortSide) : null,
        ),
      );
    }
  }
  return out;
}

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
