import 'package:material_3_expressive/material_3_expressive.dart';

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';
import 'package:soft_edge_blur/soft_edge_blur.dart';

import '../stores/downloader_store.dart';
import '../utils/image_headers.dart';
import '../theme/app_theme.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';

/// 二级页面：解析结果（含加载骨架屏 / 错误态）。
class ResultPage extends StatefulWidget {
  const ResultPage({super.key});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  int _qualityIndex = 0;
  bool _audioOnly = false;
  bool _coverOnly = false;
  bool _videoWithCover = false;
  String? _activeTaskId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final store = context.watch<DownloaderStore>();
    final source = store.source;
    final bool loading =
        store.parsing || (source == null && store.error == null);
    final MediaPart? part = (source != null && source.parts.isNotEmpty)
        ? source.parts.first
        : null;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: M3EAppBar.top(
        titleText: '解析结果',
        automaticallyImplyLeading: true,
        toolbarHeight: 64,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (Widget child, Animation<double> animation) {
                  final Animation<double> curved = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.98,
                        end: 1.0,
                      ).animate(curved),
                      child: child,
                    ),
                  );
                },
                layoutBuilder: (Widget? current, List<Widget> previous) {
                  return Stack(
                    alignment: Alignment.topCenter,
                    children: <Widget>[
                      for (final Widget child in previous)
                        Positioned.fill(child: IgnorePointer(child: child)),
                      if (current != null) Positioned.fill(child: current),
                    ],
                  );
                },
                child: loading
                    ? KeyedSubtree(
                        key: const ValueKey<String>('loading'),
                        child: _buildSkeleton(theme, scheme),
                      )
                    : (source == null
                          ? KeyedSubtree(
                              key: const ValueKey<String>('error'),
                              child: _buildError(theme, scheme, store),
                            )
                          : KeyedSubtree(
                              key: const ValueKey<String>('content'),
                              child: _buildContent(theme, scheme, source, part),
                            )),
              ),
            ),
            if (!loading &&
                source != null &&
                part != null &&
                part.streams.isNotEmpty)
              _buildBottomBar(theme, scheme, part),
          ],
        ),
      ),
    );
  }

  // ---------- 骨架屏 ----------
  Widget _buildSkeleton(ThemeData theme, ColorScheme scheme) {
    Widget bar(double h, double radius, {double? width}) =>
        _ShimmerBox(height: h, radius: radius, width: width);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: <Widget>[
        bar(208, 40),
        const SizedBox(height: 16),
        bar(28, 12, width: 300),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            bar(44, 22, width: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  bar(16, 8, width: 120),
                  const SizedBox(height: 8),
                  bar(12, 6, width: 160),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        bar(20, 8, width: 60),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            for (int i = 0; i < 4; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 2),
              Expanded(child: bar(48, 24)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        bar(12, 6, width: 160),
        const SizedBox(height: 16),
        bar(20, 8, width: 60),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            bar(40, 12, width: 96),
            const SizedBox(width: 8),
            bar(40, 12, width: 98),
            const SizedBox(width: 8),
            bar(40, 12, width: 112),
          ],
        ),
      ],
    );
  }

  // ---------- 错误态 ----------
  Widget _buildError(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              store.error ?? '解析失败',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            M3EButton.filled(
              onPressed: () => store.retry(),
              size: M3EButtonSize.md,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              tooltip: '重试',
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 内容 ----------
  Widget _buildContent(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
    MediaPart? part,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: <Widget>[
        _buildCover(theme, scheme, source, part),
        const SizedBox(height: 16),
        Text(
          source.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        _buildAuthor(theme, scheme, source),
        const SizedBox(height: 16),
        _buildQuality(theme, scheme, part, source.platform),
        const SizedBox(height: 16),
        _buildOptions(theme, scheme),
      ],
    );
  }

  Widget _buildCover(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
    MediaPart? part,
  ) {
    final String platform = source.platformLabel;
    final bool portrait = source.isPortrait;
    final double cardHeight = portrait ? 360 : 208;
    final String? url = _normalizeUrl(source.coverUrl);

    Widget coverImage() {
      if (url == null) {
        return _decorativeCover(scheme);
      }
      return Image.network(
        url,
        headers: imageHeadersFor(url),
        fit: BoxFit.cover,
        loadingBuilder:
            (BuildContext context, Widget child, ImageChunkEvent? progress) {
              if (progress == null) {
                return child;
              }
              return ColoredBox(color: scheme.surfaceContainerHighest);
            },
        errorBuilder: (
          BuildContext context,
          Object error,
          StackTrace? stackTrace,
        ) => _decorativeCover(scheme),
      );
    }

    final Widget layer = portrait
        ? Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 模糊背景铺满，避免竖屏封面两侧留白。
              Positioned.fill(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: coverImage(),
                ),
              ),
              Positioned.fill(
                child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.28)),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: AspectRatio(
                    aspectRatio: source.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      child: url == null
                          ? coverImage()
                          : _softEdgesAll(coverImage()),
                    ),
                  ),
                ),
              ),
            ],
          )
        : coverImage();

    final Color platformDot = source.platform == 'douyin'
        ? const Color(0xFF161823)
        : const Color(0xFFF25C5C);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      child: SizedBox(
        height: cardHeight,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: layer),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow, size: 34, color: scheme.primary),
              ),
            ),
            Positioned(
              left: 14,
              top: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: platformDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      platform,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _formatDuration(part?.durationSeconds),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: scheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decorativeCover(ColorScheme scheme) {
    return Container(
      color: scheme.primaryContainer,
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -50,
            top: -60,
            child: Container(
              width: 210,
              height: 210,
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer.withValues(alpha: 0.85),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: -40,
            bottom: -50,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 竖屏封面四条边的渐进模糊，弱化图片与卡片的硬边。
  Widget _softEdgesAll(Widget child) {
    return SoftEdgeBlur(
      edges: <EdgeBlur>[
        for (final EdgeType type in <EdgeType>[
          EdgeType.topEdge,
          EdgeType.bottomEdge,
          EdgeType.leftEdge,
          EdgeType.rightEdge,
        ])
          EdgeBlur(
            type: type,
            size: 20,
            sigma: 6,
            controlPoints: <ControlPoint>[
              ControlPoint(position: 0, type: ControlPointType.visible),
              ControlPoint(position: 0.55, type: ControlPointType.visible),
              ControlPoint(position: 1, type: ControlPointType.transparent),
            ],
          ),
      ],
      child: child,
    );
  }

  String? _normalizeUrl(String? raw) {
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

  Widget _buildAuthor(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
  ) {
    final author = source.author.isEmpty ? '未知作者' : source.author;
    final name = author.startsWith('@') ? author : '@$author';
    final date = source.publishDate ?? '';
    final String platformName = source.platformLabel;
    final meta = date.isEmpty ? platformName : '$date · $platformName';
    return Row(
      children: <Widget>[
        _buildAvatar(source, scheme),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvatar(ParsedSource source, ColorScheme scheme) {
    final String? url = _normalizeUrl(source.authorAvatarUrl);
    if (url == null) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.person, size: 22, color: scheme.onPrimaryContainer),
      );
    }
    return ClipOval(
      child: Image.network(
        url,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        headers: imageHeadersFor(url),
        loadingBuilder:
            (BuildContext context, Widget child, ImageChunkEvent? progress) {
              if (progress == null) {
                return child;
              }
              return const _ShimmerBox(height: 44, radius: 22, width: 44);
            },
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                Container(
                  width: 44,
                  height: 44,
                  color: scheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 22,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
      ),
    );
  }

  List<MediaStream> _videoStreams(MediaPart? part, String platform) {
    if (part == null) {
      return const <MediaStream>[];
    }
    final List<MediaStream> videos = part.streams
        .where(
          (MediaStream s) =>
              s.isVideo && s.quality > 0 && s.primaryUrl.isNotEmpty,
        )
        .toList();
    if (platform == 'douyin') {
      // 抖音同一分辨率有多档码率，全部保留（水印流已在 mapper 过滤）。
      videos.sort(
        (MediaStream a, MediaStream b) => b.quality.compareTo(a.quality),
      );
      return videos;
    }
    // B 站同一画质有 avc/hevc/av1 多条流，只保留一条并优先 avc，
    // 与 pickVideoQuality 的实际选择保持一致。
    final Map<String, MediaStream> byLabel = <String, MediaStream>{};
    for (final MediaStream s in videos) {
      final MediaStream? existing = byLabel[s.displayLabel];
      if (existing == null || (existing.codec != 'avc' && s.codec == 'avc')) {
        byLabel[s.displayLabel] = s;
      }
    }
    final List<MediaStream> list = byLabel.values.toList();
    list.sort((MediaStream a, MediaStream b) => b.quality.compareTo(a.quality));
    return list;
  }

  MediaStream? _selectedStream(MediaPart? part, String platform) {
    final List<MediaStream> list = _videoStreams(part, platform);
    if (list.isEmpty) {
      return null;
    }
    return list[_qualityIndex.clamp(0, list.length - 1)];
  }

  /// 抖音按钮带码率，区分同分辨率的不同档位；B 站保持纯画质标签。
  String _qualityButtonLabel(MediaStream stream, String platform) {
    final int? bps = stream.bitrate;
    if (platform != 'douyin' || bps == null || bps <= 0) {
      return stream.displayLabel;
    }
    final String bitrate = bps >= 1000000
        ? '${(bps / 1000000).toStringAsFixed(2)}M'
        : '${(bps / 1000).round()}K';
    return '${stream.displayLabel} · $bitrate';
  }

  /// 依据带宽与时长估算文件大小（约 xx MB）。
  String _estimateSize(MediaStream? stream, MediaPart? part) {
    final int? bandwidth = stream?.bandwidth;
    final int? duration = part?.durationSeconds;
    if (bandwidth == null ||
        bandwidth <= 0 ||
        duration == null ||
        duration <= 0) {
      return '';
    }
    final double mb = (bandwidth * duration / 8) / (1024 * 1024);
    return '约 ${mb.toStringAsFixed(1)} MB';
  }

  Widget _buildQuality(
    ThemeData theme,
    ColorScheme scheme,
    MediaPart? part,
    String platform,
  ) {
    final List<MediaStream> streams = _videoStreams(part, platform);
    final int selected = streams.isEmpty
        ? 0
        : _qualityIndex.clamp(0, streams.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '画质',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        if (streams.isEmpty)
          Text('无', style: theme.textTheme.bodyMedium)
        else
          M3EButtonGroup(
            type: M3EButtonGroupType.connected,
            direction: Axis.horizontal,
            shape: M3EButtonShape.square,
            size: M3EButtonSize.md,
            overflow: M3EButtonGroupOverflow.menu,
            selectedIndex: selected,
            style: M3EButtonStyle.filled,
            density: M3EButtonGroupDensity.regular,
            neighborSquish: true,
            expandedRatio: 0.05,
            spacing: 5,
            onSelectedIndexChanged: (int? index) {
              if (index != null) {
                setState(() => _qualityIndex = index);
              }
            },
            actions: <M3EButtonGroupAction>[
              for (final MediaStream s in streams)
                M3EButtonGroupAction(
                  label: Text(_qualityButtonLabel(s, platform)),
                  tooltip: s.detailText.isEmpty
                      ? _qualityButtonLabel(s, platform)
                      : '${_qualityButtonLabel(s, platform)} · ${s.detailText}',
                ),
            ],
          ),
        const SizedBox(height: 10),
        if (streams.isEmpty)
          Text(
            '暂无可用画质',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Text(
            '${streams[selected].displayLabel} · '
            '${_streamDetailText(streams[selected], part)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }

  String _streamDetailText(MediaStream stream, MediaPart? part) {
    final String size = stream.sizeBytes != null
        ? '${(stream.sizeBytes! / 1024 / 1024).toStringAsFixed(1)} MB'
        : _estimateSize(stream, part);
    final List<String> parts = <String>[
      if (stream.detailText.isNotEmpty) stream.detailText,
      stream.codec.toUpperCase(),
      if (size.isNotEmpty) size,
    ];
    return parts.join(' · ');
  }

  Widget _buildOptions(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '选项',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _optionChip(
              theme,
              scheme,
              label: '仅音频',
              icon: Icons.music_note,
              selected: _audioOnly,
              onTap: () => setState(() {
                _audioOnly = !_audioOnly;
                if (_audioOnly) {
                  _coverOnly = false;
                  _videoWithCover = false;
                }
              }),
            ),
            _optionChip(
              theme,
              scheme,
              label: '仅封面',
              icon: Icons.image_outlined,
              selected: _coverOnly,
              onTap: () => setState(() {
                _coverOnly = !_coverOnly;
                if (_coverOnly) {
                  _audioOnly = false;
                  _videoWithCover = false;
                }
              }),
            ),
            _optionChip(
              theme,
              scheme,
              label: '视频+封面',
              icon: Icons.collections_outlined,
              selected: _videoWithCover,
              onTap: () => setState(() {
                _videoWithCover = !_videoWithCover;
                if (_videoWithCover) {
                  _audioOnly = false;
                  _coverOnly = false;
                }
              }),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionChip(
    ThemeData theme,
    ColorScheme scheme, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? Colors.transparent : scheme.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 18,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, ColorScheme scheme, MediaPart? part) {
    final store = context.watch<DownloaderStore>();
    final DownloadTask? task = _activeTaskId == null
        ? null
        : store.taskById(_activeTaskId!);
    final bool active =
        task != null &&
        (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.paused);
    final double progress = task?.progress ?? 0;
    final bool disabled = part == null || active;
    final String label = active
        ? '下载中 ${(progress * 100).toStringAsFixed(0)}%'
        : '开始下载';
    return Container(
      color: scheme.surface,
      // edge-to-edge 下 MediaQuery.padding.bottom 被清空，用 viewPadding 补回手势区。
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        28 + M3ESafeArea.bottomOf(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: active
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: M3EProgressIndicator.linearWavy(
                        value: progress,
                        color: scheme.primary,
                        trackColor: scheme.surfaceContainerHigh,
                        strokeWidth: 4,
                        trackStrokeWidth: 4,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          SizedBox(
            width: double.infinity,
            child: M3EButton.filled(
              onPressed: () {
                if (disabled) {
                  return;
                }
                _startDownload(context, part);
              },
              enabled: !disabled,
              size: M3EButtonSize.md,
              icon: const Icon(Icons.download),
              label: Text(
                label,
                style: const TextStyle(
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              tooltip: '开始下载',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startDownload(BuildContext context, MediaPart part) async {
    final store = context.read<DownloaderStore>();
    final messenger = ScaffoldMessenger.of(context);
    final MediaStream? selected = _selectedStream(
      part,
      store.source?.platform ?? '',
    );
    final int? quality = selected?.quality;
    final String qualityText = selected?.displayLabel ?? '视频';
    final String qLabel = _audioOnly
        ? '仅音频'
        : _coverOnly
        ? '仅封面'
        : _videoWithCover
        ? '$qualityText + 封面'
        : qualityText;
    final DownloadTask task = store.startDownload(
      part,
      title: store.source?.title ?? part.title,
      platform: store.source?.platformLabel ?? '哔哩哔哩',
      qualityLabel: qLabel,
      videoQuality: (_audioOnly || _coverOnly) ? null : quality,
      audioOnly: _audioOnly,
      coverOnly: _coverOnly,
      saveCover: _videoWithCover,
      coverUrl: store.source?.coverUrl,
      sourceUrl: store.source?.sourceUrl ?? part.id,
    );
    setState(() => _activeTaskId = task.id);
    messenger.clearSnackBars();
    messenger.showSnackBar(const SnackBar(content: Text('已开始下载，可在「下载」页查看进度')));
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) {
      return '--:--';
    }
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int secs = seconds % 60;
    final String mm = minutes.toString().padLeft(2, '0');
    final String ss = secs.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }
}

/// 骨架屏的闪烁块。
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({required this.height, required this.radius, this.width});

  final double height;
  final double radius;
  final double? width;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double x = _controller.value * 2 - 1;
        return Container(
          width: widget.width ?? double.infinity,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(x - 1, 0),
              end: Alignment(x + 1, 0),
              colors: <Color>[
                scheme.surfaceContainerHigh,
                scheme.surfaceContainerLowest,
                scheme.surfaceContainerHigh,
              ],
            ),
          ),
        );
      },
    );
  }
}
