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

  // 只取无水印主视频（media.video）；没有才退回 streams 的第一条。
  Map<String, dynamic>? video = _asMapOrNull(media['video']);
  if (video == null || _streamUrls(video).isEmpty) {
    final dynamic list = media['streams'];
    if (list is List) {
      for (final dynamic item in list) {
        final Map<String, dynamic>? candidate = _asMapOrNull(item);
        if (candidate != null && _streamUrls(candidate).isNotEmpty) {
          video = candidate;
          break;
        }
      }
    }
  }
  if (video == null) {
    throw DtkUnsupported('该作品没有可下载的视频流');
  }
  // 只有 www.douyin.com/aweme/v1/play/ 这种直链可用；douyinvod 等镜像有防盗链。
  final List<String> allUrls = _streamUrls(video);
  final List<String> preferredUrls = allUrls
      .where((String u) => u.startsWith('https://www.douyin.com'))
      .toList();
  final List<String> urls = preferredUrls.isNotEmpty ? preferredUrls : allUrls;
  if (urls.isEmpty) {
    throw DtkUnsupported('该作品没有可下载的视频流');
  }

  final int width = _asInt(video['width']);
  final int height = _asInt(video['height']);
  final int quality = _quality(width, height);
  final int? bitrate = _asIntOrNull(video['bitrate']);

  final List<MediaStream> streams = <MediaStream>[
    MediaStream(
      kind: 'video',
      quality: quality,
      codec: 'avc',
      urls: urls,
      headers: _douyinHeaders,
      bandwidth: bitrate,
    ),
  ];

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

int _quality(int width, int height) {
  if (width > 0 && height > 0) {
    return math.min(width, height);
  }
  return height > 0 ? height : (width > 0 ? width : 0);
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
  return '$y-$m-$d';
}
