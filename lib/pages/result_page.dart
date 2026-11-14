import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:soft_edge_blur/soft_edge_blur.dart';
import 'package:url_launcher/url_launcher.dart';

import '../stores/downloader_store.dart';
import '../utils/format.dart';
import '../utils/image_headers.dart';
import '../utils/result.dart';
import '../theme/app_theme.dart';
import '../viewmodels/download_task.dart';
import '../viewmodels/parsed_source.dart';

/// 键盘弹起时归零、其余情况取手势条/刘海高度的底部安全区。
double _bottomInset(BuildContext context) {
  MediaQuery.viewInsetsOf(context);
  final MediaQueryData raw = MediaQueryData.fromView(View.of(context));
  return raw.viewInsets.bottom > 0 ? 0 : raw.viewPadding.bottom;
}

/// 二级页面：解析结果（含加载骨架屏 / 错误态）。
class ResultPage extends StatefulWidget {
  const ResultPage({super.key});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  int _qualityIndex = 0;
  bool _coverOnly = false;
  bool _videoWithCover = false;
  String? _activeTaskId;
  final PageController _imagePageController = PageController();
  int _imageIndex = 0;
  bool _imageSaving = false;
  double _imageProgress = 0;
  String? _imagePhase;
  String? _notifiedTaskId;

  @override
  void dispose() {
    _imagePageController.dispose();
    super.dispose();
  }

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
    _maybeNotifyTask(store);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        title: const Text('解析结果'),
        toolbarHeight: 64,
        actions: <Widget>[_buildMoreMenu(store)],
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
                          : source.isImageAlbum
                          ? KeyedSubtree(
                              key: const ValueKey<String>('album'),
                              child: _buildAlbum(theme, scheme, source),
                            )
                          : KeyedSubtree(
                              key: const ValueKey<String>('content'),
                              child: _buildContent(
                                theme,
                                scheme,
                                source,
                                part,
                                store,
                              ),
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
  void _maybeNotifyTask(DownloaderStore store) {
    final String? id = _activeTaskId;
    if (id == null || id == _notifiedTaskId) {
      return;
    }
    final DownloadTask? task = store.taskById(id);
    if (task == null || (!task.isCompleted && !task.isFailed)) {
      return;
    }
    _notifiedTaskId = task.id;
    final String message = task.isCompleted
        ? (task.savedMessage ?? '下载完成')
        : '下载失败：${task.error ?? '未知错误'}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Widget _buildError(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
  ) {
    final String? error = store.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              error ?? '解析失败',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Tooltip(
                  message: '重试',
                  child: FilledButton.icon(
                    onPressed: () => store.retry(),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 56),
                      shape: const StadiumBorder(),
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 内容 ----------
  Widget _buildAlbum(ThemeData theme, ColorScheme scheme, ParsedSource source) {
    final List<MediaImage> images = source.images;
    final int index = _imageIndex.clamp(0, images.length - 1);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + _bottomInset(context)),
      children: <Widget>[
        _buildImageGallery(theme, scheme, source, index),
        const SizedBox(height: 16),
        Text(
          source.title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        _buildAuthor(theme, scheme, source),
        const SizedBox(height: 16),
        _buildImageActions(theme, scheme, source, index),
      ],
    );
  }

  Widget _buildImageGallery(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
    int index,
  ) {
    final List<MediaImage> images = source.images;
    final MediaImage current = images[index];
    return Column(
      children: <Widget>[
        Container(
          height: 380,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              PageView.builder(
                controller: _imagePageController,
                itemCount: images.length,
                onPageChanged: (int value) {
                  if (mounted) {
                    setState(() => _imageIndex = value);
                  }
                },
                itemBuilder: (BuildContext context, int i) {
                  return _albumImage(images[i], scheme, fit: BoxFit.contain);
                },
              ),
              Positioned(
                top: 12,
                right: 12,
                child: _galleryBadge('${index + 1} / ${images.length}', scheme),
              ),
              if (current.isLive)
                Positioned(
                  top: 12,
                  left: 12,
                  child: _galleryBadge(
                    '实况',
                    scheme,
                    icon: Icons.play_circle_fill_rounded,
                  ),
                ),
            ],
          ),
        ),
        if (images.length > 1) ...<Widget>[
          const SizedBox(height: 10),
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int i) {
                final bool selected = i == index;
                return GestureDetector(
                  onTap: () {
                    _imagePageController.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                    );
                    setState(() => _imageIndex = i);
                  },
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _albumImage(
                      images[i],
                      scheme,
                      fit: BoxFit.cover,
                      cacheWidth: 140,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _albumImage(
    MediaImage image,
    ColorScheme scheme, {
    required BoxFit fit,
    int? cacheWidth,
  }) {
    final String? url = _normalizeUrl(image.primaryUrl);
    if (url == null) {
      return ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
      );
    }
    return Image.network(
      url,
      headers: imageHeadersFor(url),
      fit: fit,
      cacheWidth: cacheWidth,
      loadingBuilder:
          (BuildContext context, Widget child, ImageChunkEvent? progress) {
            if (progress == null) {
              return child;
            }
            return ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            );
          },
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
        return ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Icon(
            Icons.broken_image_outlined,
            color: scheme.onSurfaceVariant,
          ),
        );
      },
    );
  }

  Widget _galleryBadge(String text, ColorScheme scheme, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageActions(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
    int index,
  ) {
    final List<MediaImage> images = source.images;
    final MediaImage current = images[index];
    final bool anyLive = images.any((MediaImage image) => image.isLive);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_imageSaving) ...<Widget>[
          LinearProgressIndicator(
            value: _imageProgress,
            color: scheme.primary,
            backgroundColor: scheme.surfaceContainerHigh,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 6),
          Text(
            _imagePhase ?? '正在保存…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            Tooltip(
              message: current.isLive
                  ? (kIsWeb ? '分别下载图片与视频' : '合成为动态照片保存')
                  : '保存这张图片',
              child: FilledButton.icon(
                onPressed: _imageSaving
                    ? null
                    : () => _saveAlbum(
                        context,
                        source,
                        onlyIndex: index,
                        // 浏览器合成不了 Motion Photo，直接把两半都交给用户。
                        separateLive: kIsWeb,
                      ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 56),
                  shape: const StadiumBorder(),
                  textStyle: theme.textTheme.titleMedium,
                ),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  _imageSaving
                      ? '保存中…'
                      : current.isLive
                      ? (kIsWeb ? '保存图片+视频' : '保存实况')
                      : '保存这张',
                ),
              ),
            ),
            if (current.isLive && !kIsWeb)
              Tooltip(
                message: '图片和视频分别保存',
                child: OutlinedButton.icon(
                  onPressed: _imageSaving
                      ? null
                      : () => _saveAlbum(
                          context,
                          source,
                          onlyIndex: index,
                          separateLive: true,
                        ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    shape: const StadiumBorder(),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('图片+视频'),
                ),
              ),
            if (images.length > 1)
              Tooltip(
                message: kIsWeb ? '打包全部图片与实况视频' : '保存全部图片',
                child: TextButton(
                  onPressed: _imageSaving
                      ? null
                      : () => _saveAlbum(
                          context,
                          source,
                          // web 上打包就不能只留静态图，否则实况视频全丢。
                          separateLive: kIsWeb && anyLive,
                        ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                  child: Text('保存全部 ${images.length} 张'),
                ),
              ),
          ],
        ),
        if (anyLive) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            kIsWeb
                ? '网页版无法合成动态照片，将分别下载图片与视频。'
                : '实况图默认合成为动态照片；相册不识别时请改用「图片+视频」。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _saveAlbum(
    BuildContext context,
    ParsedSource source, {
    int? onlyIndex,
    bool separateLive = false,
  }) async {
    if (_imageSaving) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _imageSaving = true;
      _imageProgress = 0;
      _imagePhase = '正在准备…';
    });
    Result<String> result;
    try {
      result = await context.read<DownloaderStore>().saveImages(
        source,
        onlyIndex: onlyIndex,
        separateLive: separateLive,
        onProgress: (DownloadProgress progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _imageProgress = progress.fraction;
            _imagePhase = progress.phase;
          });
        },
      );
    } catch (e) {
      result = Err<String>(AppError('保存图片失败：$e', cause: e));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _imageSaving = false;
      _imageProgress = 0;
      _imagePhase = null;
    });
    messenger.clearSnackBars();
    if (result is Ok<String>) {
      messenger.showSnackBar(SnackBar(content: Text(result.value)));
    } else if (result is Err<String>) {
      messenger.showSnackBar(SnackBar(content: Text(result.error.message)));
    }
  }

  Widget _buildMoreMenu(DownloaderStore store) {
    final String? url = store.source?.sourceUrl;
    return MenuAnchor(
      // 菜单贴在按钮下方、右对齐。
      style: const MenuStyle(alignment: Alignment.bottomRight),
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
            return IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多',
              onPressed: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
            );
          },
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.link_rounded),
          onPressed: url == null ? null : () => _copySource(url),
          child: const Text('复制原链接'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new_rounded),
          onPressed: url == null ? null : () => _openSource(url),
          child: const Text('在浏览器打开'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.refresh_rounded),
          onPressed: () => unawaited(store.retry()),
          child: const Text('重新解析'),
        ),
      ],
    );
  }

  Future<void> _copySource(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(const SnackBar(content: Text('原链接已复制')));
  }

  Future<void> _openSource(String url) async {
    try {
      final bool opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw Exception('无法打开浏览器');
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text('打开原链接失败：$e')));
    }
  }

  Widget _buildContent(
    ThemeData theme,
    ColorScheme scheme,
    ParsedSource source,
    MediaPart? part,
    DownloaderStore store,
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

    const Color platformDot = Color(0xFF161823);

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
    final String author = source.author.isEmpty ? '未知作者' : source.author;
    final String name = author.startsWith('@') ? author : '@$author';
    final String date = source.publishDate ?? '';
    final int? likes = source.likeCount;
    final List<String> metaParts = <String>[
      if (date.isNotEmpty) date,
      if (likes != null && likes > 0) '赞 ${formatCount(likes)}',
    ];
    final String meta = metaParts.isEmpty
        ? source.platformLabel
        : metaParts.join(' · ');
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

  List<MediaStream> _videoStreams(MediaPart? part) {
    if (part == null) {
      return const <MediaStream>[];
    }
    // 抖音同一分辨率有多档码率，全部保留（水印流已在 mapper 过滤）。
    final List<MediaStream> videos =
        part.streams
            .where(
              (MediaStream s) =>
                  s.isVideo && s.quality > 0 && s.primaryUrl.isNotEmpty,
            )
            .toList()
          ..sort(
            (MediaStream a, MediaStream b) => b.quality.compareTo(a.quality),
          );
    return videos;
  }

  MediaStream? _selectedStream(MediaPart? part) {
    final List<MediaStream> list = _videoStreams(part);
    if (list.isEmpty) {
      return null;
    }
    return list[_qualityIndex.clamp(0, list.length - 1)];
  }

  /// 同分辨率有多档码率时，按钮上直接带码率便于区分。
  String _qualityButtonLabel(MediaStream stream) {
    final int? bps = stream.bitrate;
    if (bps == null || bps <= 0) {
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

  /// 横向选项只构建视口附近的项目，多码率列表不会一次全建。
  Widget _buildLazyChoiceRow({
    required int count,
    required double height,
    required Widget Function(int index) itemBuilder,
  }) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (BuildContext context, int index) => itemBuilder(index),
      ),
    );
  }

  /// 画质选择按钮：选中深色填充，未选中浅色底，圆角 8。
  Widget _choiceButton({
    required ThemeData theme,
    required ColorScheme scheme,
    required String label,
    required String tooltip,
    required bool selected,
    required bool enabled,
    required double height,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: enabled ? onPressed : null,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(Size(0, height)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 14),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            theme.textTheme.labelLarge,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: const WidgetStatePropertyAll<BorderSide?>(BorderSide.none),
          backgroundColor: WidgetStatePropertyAll<Color?>(
            selected ? scheme.primary : scheme.secondaryContainer,
          ),
          foregroundColor: WidgetStatePropertyAll<Color?>(
            selected ? scheme.onPrimary : scheme.onSecondaryContainer,
          ),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _buildQuality(
    ThemeData theme,
    ColorScheme scheme,
    MediaPart? part,
    String platform,
  ) {
    final List<MediaStream> streams = _videoStreams(part);
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
          _buildLazyChoiceRow(
            count: streams.length,
            height: 42,
            itemBuilder: (int i) {
              final MediaStream stream = streams[i];
              final bool active = i == selected;
              return _choiceButton(
                theme: theme,
                scheme: scheme,
                label: _qualityButtonLabel(stream),
                tooltip: stream.detailText.isEmpty
                    ? _qualityButtonLabel(stream)
                    : '${_qualityButtonLabel(stream)} · ${stream.detailText}',
                selected: active,
                enabled: true,
                height: 42,
                onPressed: () {
                  if (!active) {
                    setState(() => _qualityIndex = i);
                  }
                },
              );
            },
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
              label: '仅封面',
              icon: Icons.image_outlined,
              selected: _coverOnly,
              onTap: () => setState(() {
                _coverOnly = !_coverOnly;
                if (_coverOnly) {
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
            task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.paused);
    final double progress = task?.progress ?? 0;
    final bool disabled = part == null || active;
    final String label = task?.status == DownloadStatus.queued
        ? '排队中'
        : task?.status == DownloadStatus.paused
        ? '已暂停'
        : active
        ? '下载中 ${(progress * 100).toStringAsFixed(0)}%'
        : '开始下载';
    return Container(
      color: scheme.surface,
      padding: EdgeInsets.fromLTRB(16, 12, 16, 28 + _bottomInset(context)),
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
                      child: LinearProgressIndicator(
                        value: progress,
                        color: scheme.primary,
                        backgroundColor: scheme.surfaceContainerHigh,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          SizedBox(
            width: double.infinity,
            child: Tooltip(
              message: '开始下载',
              child: FilledButton.icon(
                onPressed: disabled
                    ? null
                    : () => _startDownload(context, part),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 56),
                  shape: const StadiumBorder(),
                  textStyle: theme.textTheme.titleMedium,
                ),
                icon: const Icon(Icons.download),
                label: Text(
                  label,
                  style: const TextStyle(
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startDownload(BuildContext context, MediaPart part) async {
    final store = context.read<DownloaderStore>();
    final messenger = ScaffoldMessenger.of(context);
    final MediaStream? selected = _selectedStream(part);
    final int? quality = selected?.quality;
    final String qualityText = selected?.displayLabel ?? '视频';
    final String qLabel = _coverOnly
        ? '仅封面'
        : _videoWithCover
        ? '$qualityText + 封面'
        : qualityText;
    // web 版没有队列：算好文件名直接把链接交给浏览器，不留任务记录。
    if (kIsWeb) {
      final Result<String> result = await store.downloadToBrowser(
        part,
        videoQuality: _coverOnly ? null : quality,
        coverOnly: _coverOnly,
        saveCover: _videoWithCover,
      );
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result is Ok<String>
                ? '已交给浏览器下载'
                : (result as Err<String>).error.message,
          ),
        ),
      );
      return;
    }

    final DownloadTask task = store.startDownload(
      part,
      title: store.source?.title ?? part.title,
      platform: store.source?.platformLabel ?? '抖音',
      qualityLabel: qLabel,
      videoQuality: _coverOnly ? null : quality,
      coverOnly: _coverOnly,
      saveCover: _videoWithCover,
      coverUrl: store.source?.coverUrl,
      sourceUrl: store.source?.sourceUrl ?? part.id,
      source: store.source,
    );
    setState(() => _activeTaskId = task.id);
    _notifiedTaskId = null;
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
