/// 解析后的 B 站来源，用于下载器页面。
class ParsedSource {
  const ParsedSource({
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.parts,
    this.publishDate,
    this.ownerMid,
    this.authorAvatarUrl,
  });

  final String title;
  final String author;
  final String? coverUrl;
  final String? publishDate;
  final int? ownerMid;
  final String? authorAvatarUrl;
  final List<MediaPart> parts;
}

class MediaPart {
  const MediaPart({
    required this.id,
    required this.title,
    required this.durationSeconds,
    required this.streams,
  });

  final String id;
  final String title;
  final int? durationSeconds;
  final List<MediaStream> streams;

  /// 优先按 codec 选最高画质的视频流；没有匹配再退回任意视频流。
  MediaStream? pickVideo({String preferredCodec = 'avc'}) {
    final videos = streams.where((s) => s.kind == 'video').toList();
    if (videos.isEmpty) {
      return null;
    }
    final preferred = videos.where((s) => s.codec == preferredCodec).toList();
    final pool = preferred.isNotEmpty ? preferred : videos;
    pool.sort((a, b) => b.quality.compareTo(a.quality));
    return pool.first;
  }

  /// 按指定画质选视频流；为空或不存在时回退到最优 avc。
  MediaStream? pickVideoQuality(int? quality) {
    if (quality == null) {
      return pickVideo();
    }
    final videos = streams.where((s) => s.kind == 'video').toList();
    if (videos.isEmpty) {
      return null;
    }
    final match = videos.where((s) => s.quality == quality).toList();
    if (match.isEmpty) {
      return pickVideo();
    }
    final avc = match.where((s) => s.codec == 'avc').toList();
    final pool = avc.isNotEmpty ? avc : match;
    pool.sort((a, b) => b.quality.compareTo(a.quality));
    return pool.first;
  }

  MediaStream? pickAudio() {
    final audios = streams.where((s) => s.kind == 'audio').toList();
    if (audios.isEmpty) {
      return null;
    }
    audios.sort((a, b) => b.quality.compareTo(a.quality));
    return audios.first;
  }
}

class MediaStream {
  const MediaStream({
    required this.kind,
    required this.quality,
    required this.codec,
    required this.urls,
    required this.headers,
    this.bandwidth,
  });

  final String kind;
  final int quality;
  final String codec;
  final List<String> urls;
  final Map<String, String> headers;
  final int? bandwidth;

  bool get isVideo => kind == 'video';

  String get primaryUrl => urls.isEmpty ? '' : urls.first;
}

/// B 站清晰度数值转可读文案。
String qualityLabel(int qn) {
  const labels = <int, String>{
    16: '360P',
    32: '480P',
    64: '720P',
    74: '720P60',
    80: '1080P',
    112: '1080P+',
    116: '1080P60',
    120: '4K',
    125: 'HDR',
    126: '杜比视界',
    127: '8K',
  };
  final label = labels[qn];
  return label ?? 'QN$qn';
}
