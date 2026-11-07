/// 解析后的作品来源（视频或图文/图集）。
class ParsedSource {
  const ParsedSource({
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.parts,
    this.images = const <MediaImage>[],
    this.publishDate,
    this.ownerMid,
    this.authorAvatarUrl,
    this.platform = 'bilibili',
    this.sourceUrl,
    this.videoWidth,
    this.videoHeight,
  });

  final String title;
  final String author;
  final String? coverUrl;
  final String? publishDate;
  final int? ownerMid;
  final String? authorAvatarUrl;
  final List<MediaPart> parts;

  /// 图文/图集图片；实况图的短视频挂在每张图的 liveVideo 上。
  final List<MediaImage> images;

  /// 来源平台：bilibili / douyin / tiktok。
  final String platform;

  /// 可重新解析的原始页面地址（B 站为视频页，抖音为 web_url），用于历史记录重解析。
  final String? sourceUrl;

  /// 视频像素宽高（用于横竖屏判断与封面比例），未知为 null。
  final int? videoWidth;
  final int? videoHeight;

  /// 平台展示名。
  String get platformLabel {
    switch (platform) {
      case 'douyin':
        return '抖音';
      case 'tiktok':
        return 'TikTok';
      default:
        return '哔哩哔哩';
    }
  }

  /// 竖屏：高 > 宽*1.05（对齐 douyinDL 脚本的判定）。
  bool get isPortrait {
    final int w = videoWidth ?? 0;
    final int h = videoHeight ?? 0;
    return w > 0 && h > 0 && h > w * 1.05;
  }

  /// 横屏：宽 > 高*1.05。
  bool get isLandscape {
    final int w = videoWidth ?? 0;
    final int h = videoHeight ?? 0;
    return w > 0 && h > 0 && w > h * 1.05;
  }

  /// 图文/图集（无视频流，只有图片）。
  bool get isImageAlbum => images.isNotEmpty && parts.isEmpty;

  /// 封面宽高比，未知时按 16:9。
  double get aspectRatio {
    final int w = videoWidth ?? 0;
    final int h = videoHeight ?? 0;
    if (w > 0 && h > 0) {
      return w / h;
    }
    return 16 / 9;
  }
}

/// 图文/图集中的一张图片；实况图额外带一段短视频。
class MediaImage {
  const MediaImage({
    required this.urls,
    this.width,
    this.height,
    this.liveVideo,
  });

  final List<String> urls;
  final int? width;
  final int? height;
  final MediaStream? liveVideo;

  String get primaryUrl => urls.isEmpty ? '' : urls.first;

  bool get isLive => liveVideo != null && liveVideo!.primaryUrl.isNotEmpty;

  String get sizeText =>
      (width != null && height != null) ? '$width×$height' : '';

  double get aspectRatio {
    final int w = width ?? 0;
    final int h = height ?? 0;
    if (w > 0 && h > 0) {
      return w / h;
    }
    return 3 / 4;
  }
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
    this.width,
    this.height,
    this.fps,
    this.bitrate,
    this.sizeBytes,
    this.resolutionLabel,
  });

  final String kind;
  final int quality;
  final String codec;
  final List<String> urls;
  final Map<String, String> headers;
  final int? bandwidth;

  /// 像素尺寸、帧率、码率（bps）——抖音等平台可提供，B 站通常为空。
  final int? width;
  final int? height;
  final int? fps;
  final int? bitrate;

  /// 精确文件大小（字节），来自 DTK 归一化流信息。
  final int? sizeBytes;

  /// 画质短标签，如 1080P；为空时回退 qualityLabel(quality)。
  final String? resolutionLabel;

  bool get isVideo => kind == 'video';

  String get primaryUrl => urls.isEmpty ? '' : urls.first;

  /// 显示用画质标签。
  String get displayLabel => resolutionLabel ?? qualityLabel(quality);

  /// 分辨率文本，如 1080×1920。
  String get resolutionText =>
      (width != null && height != null) ? '$width×$height' : '';

  /// 帧率文本，如 30fps。
  String get fpsText => fps != null ? '${fps}fps' : '';

  /// 码率文本，如 2.4Mbps。
  String get bitrateText =>
      bitrate != null ? '${(bitrate! / 1000000).toStringAsFixed(1)}Mbps' : '';

  /// 汇总详情：分辨率 · 帧率 · 码率（缺项省略）。
  String get detailText {
    final List<String> parts = <String>[
      if (resolutionText.isNotEmpty) resolutionText,
      if (fpsText.isNotEmpty) fpsText,
      if (bitrateText.isNotEmpty) bitrateText,
    ];
    return parts.join(' · ');
  }
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
  if (label != null) {
    return label;
  }
  // 抖音等平台用像素高（如 720/1080）作为质量值，直接渲染为 720P/1080P。
  if (qn >= 240) {
    return '$qn'
        'P';
  }
  return 'QN$qn';
}
