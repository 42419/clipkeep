import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../stores/downloader_store.dart';
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
  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

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
            if (!loading && source != null)
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
        _buildCover(theme, scheme, source.coverUrl, part),
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
        _buildQuality(theme, scheme, part),
        const SizedBox(height: 16),
        _buildOptions(theme, scheme),
      ],
    );
  }

  Widget _buildCover(
    ThemeData theme,
    ColorScheme scheme,
    String? coverUrl,
    MediaPart? part,
  ) {
    const String platform = '哔哩哔哩';
    final String? url = _normalizeUrl(coverUrl);
    final Widget background = url == null
        ? _decorativeCover(scheme)
        : Image.network(
            url,
            headers: _imageHeaders,
            fit: BoxFit.cover,
            width: double.infinity,
            height: 208,
            loadingBuilder:
                (
                  BuildContext context,
                  Widget child,
                  ImageChunkEvent? progress,
                ) {
                  if (progress == null) {
                    return child;
                  }
                  return _ShimmerBox(height: 208, radius: AppTheme.radiusXl);
                },
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) => _decorativeCover(scheme),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      child: SizedBox(
        height: 208,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: background),
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
                      decoration: const BoxDecoration(
                        color: Color(0xFFF25C5C),
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
      height: 208,
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
    final meta = date.isEmpty ? '哔哩哔哩' : '$date · 哔哩哔哩';
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
        headers: _imageHeaders,
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

  List<int> _qualities(MediaPart? part) {
    if (part == null) {
      return const <int>[];
    }
    final set = <int>{};
    for (final stream in part.streams) {
      // 只统计真实存在且有下载地址的视频画质（跳过 Best/unknown 与空地址）。
      if (stream.isVideo &&
          stream.quality > 0 &&
          stream.primaryUrl.isNotEmpty) {
        set.add(stream.quality);
      }
    }
    return set.toList()..sort((int a, int b) => b.compareTo(a));
  }

  MediaStream? _selectedStream(MediaPart? part, List<int> qualities) {
    if (part == null || qualities.isEmpty) {
      return null;
    }
    final int q = qualities[_qualityIndex.clamp(0, qualities.length - 1)];
    final matches = part.streams
        .where((MediaStream s) => s.isVideo && s.quality == q)
        .toList();
    if (matches.isEmpty) {
      return null;
    }
    final avc = matches.where((MediaStream s) => s.codec == 'avc').toList();
    return avc.isNotEmpty ? avc.first : matches.first;
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

  Widget _buildQuality(ThemeData theme, ColorScheme scheme, MediaPart? part) {
    final qualities = _qualities(part);
    final stream = _selectedStream(part, qualities);
    final String size = _estimateSize(stream, part);
    final pieces = <String>[
      if (stream != null) qualityLabel(stream.quality),
      if (stream != null) stream.codec.toUpperCase(),
      if (size.isNotEmpty) size,
    ];
    final meta = pieces.isEmpty ? '暂无可用画质' : pieces.join(' · ');
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
        if (qualities.isEmpty)
          Text('无', style: theme.textTheme.bodyMedium)
        else
          M3EButtonGroup(
            type: M3EButtonGroupType.connected,
            direction: Axis.horizontal,
            shape: M3EButtonShape.square,
            size: M3EButtonSize.md,
            overflow: M3EButtonGroupOverflow.menu,
            selectedIndex: _qualityIndex.clamp(0, qualities.length - 1),
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
              for (final int q in qualities)
                M3EButtonGroupAction(
                  // selectedIcon: const Icon(M3EIcons.check),
                  label: Text(qualityLabel(q)),
                  tooltip: qualityLabel(q),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Text(
          meta,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
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
              label: '无水印',
              icon: Icons.check,
              selected: true,
              onTap: () => _notify('B 站视频本身无水印'),
            ),
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
    final DownloadTask? task =
        _activeTaskId == null ? null : store.taskById(_activeTaskId!);
    final bool active = task != null &&
        (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.paused);
    final double progress = task?.progress ?? 0;
    final bool disabled = part == null || active;
    final String label = active
        ? '下载中 ${(progress * 100).toStringAsFixed(0)}%'
        : '开始下载';
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
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
    final qualities = _qualities(part);
    final int? quality = qualities.isEmpty
        ? null
        : qualities[_qualityIndex.clamp(0, qualities.length - 1)];
    final String qualityText = quality == null ? '视频' : qualityLabel(quality);
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
      qualityLabel: qLabel,
      videoQuality: (_audioOnly || _coverOnly) ? null : quality,
      audioOnly: _audioOnly,
      coverOnly: _coverOnly,
      saveCover: _videoWithCover,
      coverUrl: store.source?.coverUrl,
    );
    setState(() => _activeTaskId = task.id);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      const SnackBar(content: Text('已开始下载，可在「下载」页查看进度')),
    );
  }

  void _notify(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
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
