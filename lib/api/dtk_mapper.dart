import 'dart:math' as math;

import '../viewmodels/parsed_source.dart';

/// 抖音直链请求头（桌面 UA + Referer/Origin + Sec-Fetch）。
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
  final Map<String, dynamic> media = _asMap(content['media']);
  final Map<String, dynamic> author = _asMap(content['author']);

  final String rawTitle = content['title']?.toString().trim() ?? '';
  final String description = content['description']?.toString().trim() ?? '';
  // 图文/图集没有视频流：不报错，返回图片列表；实况图的视频挂在图片上。
  final List<MediaImage> images = _buildImages(media);
  final bool isAlbum =
      content['kind']?.toString() == 'image_album' || images.isNotEmpty;
  final String title = isAlbum
      ? _shortTitle(rawTitle.isNotEmpty ? rawTitle : description)
      : (rawTitle.isNotEmpty ? rawTitle : _shortTitle(description));
  final String authorName = author['nickname']?.toString() ?? '';
  final String? avatar = _imageUrl(_asMapOrNull(author['avatar']));
  final String? cover = _firstImageUrl(media['covers']);
  final String webUrl = content['web_url']?.toString() ?? '';
  final int durationMs = _asInt(content['duration_ms']);
  final String? publishDate = _formatDate(content['created_at']);
  final Map<String, dynamic> stats = _asMap(content['stats']);

  final List<MediaStream> streams = _buildStreams(content, media);
  final MediaStream? primary = streams.isNotEmpty ? streams.first : null;
  int width = primary?.width ?? 0;
  int height = primary?.height ?? 0;
  if (width == 0 || height == 0) {
    // 图文/图集没有视频流时，用第一张图片/封面尺寸判断横竖屏。
    final MediaImage? firstImage = images.isNotEmpty ? images.first : null;
    width = firstImage?.width ?? 0;
    height = firstImage?.height ?? 0;
    if (width == 0 || height == 0) {
      final dynamic coverList = media['covers'];
      if (coverList is List && coverList.isNotEmpty) {
        final Map<String, dynamic> cover0 = _asMap(coverList.first);
        width = _asInt(cover0['width']);
        height = _asInt(cover0['height']);
      }
    }
  }

  final String partId = webUrl.isNotEmpty
      ? webUrl
      : (content['content_id']?.toString() ?? '');
  return ParsedSource(
    title: title,
    author: authorName,
    coverUrl: cover ?? (images.isNotEmpty ? images.first.primaryUrl : null),
    publishDate: publishDate,
    likeCount: _asIntOrNull(stats['digg_count']),
    authorAvatarUrl: avatar,
    platform: 'douyin',
    sourceUrl: webUrl.isNotEmpty ? webUrl : null,
    videoWidth: width,
    videoHeight: height,
    images: images,
    parts: streams.isEmpty
        ? const <MediaPart>[]
        : <MediaPart>[
            MediaPart(
              id: partId,
              title: title,
              durationSeconds: durationMs > 0
                  ? (durationMs / 1000).round()
                  : null,
              streams: streams,
            ),
          ],
  );
}

/// 图文/图集标题只取正文首行并截断，避免长文案把结果页标题撑开。
String _shortTitle(String description) {
  final String line = description.split('\n').first.trim();
  if (line.isEmpty) {
    return '抖音作品';
  }
  return line.length <= 60 ? line : '${line.substring(0, 60)}…';
}

List<MediaImage> _buildImages(Map<String, dynamic> media) {
  final dynamic list = media['images'];
  if (list is! List) {
    return const <MediaImage>[];
  }
  final List<MediaImage> out = <MediaImage>[];
  for (final dynamic item in list) {
    final Map<String, dynamic>? node = _asMapOrNull(item);
    if (node == null) {
      continue;
    }
    final List<String> urls = _imageUrls(node);
    if (urls.isEmpty) {
      continue;
    }
    out.add(
      MediaImage(
        urls: urls,
        width: _asIntOrNull(node['width']),
        height: _asIntOrNull(node['height']),
        liveVideo: _liveVideo(node['video']),
      ),
    );
  }
  return out;
}

/// 实况图的视频：DTK 归一化后是 VideoStream，直接保留多镜像地址。
MediaStream? _liveVideo(dynamic raw) {
  final Map<String, dynamic>? node = _asMapOrNull(raw);
  if (node == null || node['watermark'] == true) {
    return null;
  }
  final List<String> urls = _streamUrls(node);
  if (urls.isEmpty) {
    return null;
  }
  final int width = _asInt(node['width']);
  final int height = _asInt(node['height']);
  return MediaStream(
    kind: 'video',
    quality: height > 0 ? height : 1,
    codec: 'avc',
    urls: urls,
    headers: _douyinHeaders,
    width: width > 0 ? width : null,
    height: height > 0 ? height : null,
    bitrate: _asIntOrNull(node['bitrate']),
    sizeBytes: _asIntOrNull(node['size_bytes'] ?? node['data_size']),
    resolutionLabel: height > 0 ? _resolutionLabel(height) : null,
  );
}

List<String> _imageUrls(Map<String, dynamic> node) {
  final List<String> out = <String>[];
  void add(dynamic raw) {
    final String url = raw?.toString().trim() ?? '';
    if (url.startsWith('http') && !out.contains(url)) {
      out.add(url);
    }
  }

  add(node['url']);
  final dynamic urls = node['urls'];
  if (urls is List) {
    for (final dynamic value in urls) {
      add(value);
    }
  }
  // 原始响应用的是 url_list；归一化缺失时也能回退。
  final dynamic urlList = node['url_list'];
  if (urlList is List) {
    for (final dynamic value in urlList) {
      add(value);
    }
  }
  return out;
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
    // 抖音的 download_addr（下载地址）带烧录水印，DTK 标为 watermark=true。
    // 本项目只提供无水印下载，直接丢弃，避免它按尺寸/体积混进画质列表。
    if (node['watermark'] == true) {
      return;
    }
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
  // 原始抖音响应里是 url_list；DTK 归一化缺失时可回退。
  final dynamic urlList = item['url_list'];
  if (urlList is List) {
    for (final dynamic value in urlList) {
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
