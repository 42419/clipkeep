/// 解析后的作品来源（视频或图文/图集）。
class ParsedSource {
  const ParsedSource({
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.parts,
    this.images = const <MediaImage>[],
    this.likeCount,
    this.publishDate,
    this.authorAvatarUrl,
    this.platform = 'douyin',
    this.sourceUrl,
    this.videoWidth,
    this.videoHeight,
  });

  final String title;
  final String author;
  final String? coverUrl;
  final String? publishDate;
  final String? authorAvatarUrl;
  final List<MediaPart> parts;

  /// 图文/图集图片；实况图的短视频挂在每张图的 liveVideo 上。
  final List<MediaImage> images;

  /// 点赞数（抖音 stats.digg_count），未知为 null。
  final int? likeCount;

  /// 来源平台：抖音。
  final String platform;

  /// 可重新解析的原始页面地址（抖音 web_url），用于历史记录重解析。
  final String? sourceUrl;

  /// 视频像素宽高（用于横竖屏判断与封面比例），未知为 null。
  final int? videoWidth;
  final int? videoHeight;

  /// 平台展示名。
  String get platformLabel => '抖音';

  /// 竖屏：高 > 宽*1.05。
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
      // 抖音 quality 含同分辨率名次，刷新后 rank 可能变化；只允许按同短边回退。
      if (quality >= 1000) {
        final int shortSide = quality ~/ 1000;
        final List<MediaStream> sameSize = videos.where((MediaStream s) {
          final int w = s.width ?? 0;
          final int h = s.height ?? 0;
          final int short = w > 0 && h > 0 ? (w < h ? w : h) : (h > 0 ? h : w);
          return short == shortSide;
        }).toList();
        if (sameSize.isNotEmpty) {
          sameSize.sort((MediaStream a, MediaStream b) {
            final int byQuality = b.quality.compareTo(a.quality);
            if (byQuality != 0) {
              return byQuality;
            }
            return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
          });
          return sameSize.first;
        }
      }
      // 刷新地址后码率档位可能变化：宁可报错，也不静默下载另一档。
      return null;
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

  /// 手动重试时判断新旧流是否仍是同一选择，决定能否复用临时分片。
  /// 除画质外必须校验 codec 与带宽/大小，避免把另一编码的文件续接成坏文件。
  bool sameDownloadSelection(MediaPart other, {int? videoQuality}) {
    final MediaStream? oldAudio = pickAudio();
    final MediaStream? newAudio = other.pickAudio();
    final MediaStream? oldVideo = pickVideoQuality(videoQuality);
    final MediaStream? newVideo = other.pickVideoQuality(videoQuality);
    if (oldVideo == null ||
        newVideo == null ||
        !_sameVideoStream(oldVideo, newVideo)) {
      return false;
    }
    if ((oldAudio == null) != (newAudio == null)) {
      return false;
    }
    return oldAudio == null || _sameAudioStream(oldAudio, newAudio!);
  }

  bool _sameVideoStream(MediaStream a, MediaStream b) {
    if (a.quality != b.quality || a.codec.isEmpty || a.codec != b.codec) {
      return false;
    }
    return _sameTransportIdentity(a, b, requireMeta: true);
  }

  bool _sameAudioStream(MediaStream a, MediaStream b) {
    if (a.quality != b.quality) {
      return false;
    }
    if (a.codec.isNotEmpty && b.codec.isNotEmpty && a.codec != b.codec) {
      return false;
    }
    return _sameTransportIdentity(a, b, requireMeta: true);
  }

  bool _sameTransportIdentity(
    MediaStream a,
    MediaStream b, {
    required bool requireMeta,
  }) {
    final int? as = a.sizeBytes;
    final int? bs = b.sizeBytes;
    if (as != null || bs != null) {
      if (as != bs) {
        return false;
      }
    }
    final int? ab = a.bandwidth;
    final int? bb = b.bandwidth;
    if (ab != null || bb != null) {
      if (ab != bb) {
        return false;
      }
    }
    if (requireMeta && as == null && bs == null && ab == null && bb == null) {
      return false;
    }
    return true;
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

  /// 像素尺寸、帧率、码率（bps）——DTK 能提供时展示。
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

/// 画质数值转可读文案。
///
/// 抖音用「短边 × 1000 + 同分辨率名次」作为 quality（如 1080999），
/// 也兼容直接传短边的旧数据（如 1080）。
String qualityLabel(int qn) {
  if (qn >= 1000) {
    final int shortSide = qn ~/ 1000;
    if (shortSide >= 240) {
      return '${shortSide}P';
    }
  }
  if (qn >= 240) {
    return '${qn}P';
  }
  return 'QN$qn';
}
