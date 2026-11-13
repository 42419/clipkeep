import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../stores/downloader_store.dart';
import '../../stores/main_tab_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../utils/image_headers.dart';
import '../../viewmodels/download_task.dart';
import '../motion/motion_compose_page.dart';
import '../result_page.dart';

/// 首页。
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  final TextEditingController _input = TextEditingController();
  bool _openingResult = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text?.trim();
      if (!mounted) {
        return;
      }
      if (text == null || text.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('剪贴板没有可粘贴的文本')));
        return;
      }
      setState(() {
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('读取剪贴板失败')));
    }
  }

  Future<void> _parse() async {
    // 结果页是 push 出来的：连点会在解析完成前叠出多个页面，共用同一份解析状态。
    if (_openingResult) {
      return;
    }
    FocusScope.of(context).unfocus();
    final text = _input.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (text.isEmpty) {
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('请先粘贴视频链接')));
      return;
    }
    // 立即跳转，解析在网络请求进行中完成，结果页展示骨架屏。
    final store = context.read<DownloaderStore>();
    _openingResult = true;
    try {
      unawaited(store.parse(text));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const ResultPage(),
        ),
      );
    } finally {
      _openingResult = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = context.watch<DownloaderStore>();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.pagePadding,
            8,
            AppTheme.pagePadding,
            16,
          ),
          children: <Widget>[
            _buildHeader(theme, scheme),
            const SizedBox(height: AppTheme.gap),
            _buildPasteCard(theme, scheme, controller),
            const SizedBox(height: AppTheme.gap),
            _buildRecent(theme, scheme, controller),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'ClipKeep',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '粘贴分享链接，一键保存视频',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // 实况图合成依赖 Android 原生 Bitmap 与相册写入，web 上不提供入口。
          if (!kIsWeb)
            Material(
              color: scheme.tertiaryContainer,
              shape: MaterialShapeBorder(shape: MaterialShapes.cookie12Sided),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                tooltip: '实况图合成',
                icon: Icon(
                  Icons.auto_awesome_motion_outlined,
                  size: 22,
                  color: scheme.onTertiaryContainer,
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          const MotionComposePage(),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPasteCard(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore controller,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '粘贴视频链接',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 56,
            padding: const EdgeInsets.only(left: 16, right: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.link, size: 22, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _parse(),
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '粘贴抖音分享链接',
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                IconButton.filled(
                  icon: const Icon(Icons.content_paste),
                  tooltip: '粘贴',
                  onPressed: _paste,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Tooltip(
              message: controller.parsing ? '解析中…' : '解析视频',
              child: FilledButton.icon(
                onPressed: controller.parsing ? null : _parse,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 56),
                  shape: const StadiumBorder(),
                  textStyle: theme.textTheme.titleMedium,
                ),
                icon: const Icon(Icons.search),
                label: Text(controller.parsing ? '解析中…' : '解析视频'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecent(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
  ) {
    // web 版没有下载队列，这里永远是空的，整块不渲染。
    if (kIsWeb) {
      return const SizedBox.shrink();
    }
    final tasks = store.completedTasks.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '最近下载',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Tooltip(
                message: '查看全部下载',
                child: TextButton(
                  onPressed: () => context
                      .read<MainTabController>()
                      .openDownloads(section: 1),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: const Text('全部'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.video_library_outlined,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '还没有下载记录',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '解析并下载后，这里会显示最近的视频',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            children: <Widget>[
              for (final (int index, DownloadTask task) in tasks.indexed)
                Padding(
                  padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => context
                          .read<MainTabController>()
                          .openDownloads(section: 1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _recentThumb(
                                scheme,
                                task.thumbnailPath,
                                task.coverUrl,
                                index.isEven
                                    ? scheme.primaryContainer
                                    : scheme.tertiaryContainer,
                                index.isEven
                                    ? scheme.onPrimaryContainer
                                    : scheme.onTertiaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    task.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${task.platform} · ${task.qualityLabel} · ${formatBytes(task.totalBytes > 0 ? task.totalBytes : task.receivedBytes)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _recentThumb(
    ColorScheme scheme,
    String? thumbnailPath,
    String? coverUrl,
    Color thumbColor,
    Color iconColor,
  ) {
    final Widget fallback = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: thumbColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(Icons.play_arrow, color: iconColor, size: 26),
    );
    final String? url = _normalizeUrl(coverUrl);
    final Widget network = url == null
        ? fallback
        : Image.network(
            url,
            width: 60,
            height: 60,
            fit: BoxFit.cover,
            headers: imageHeadersFor(url),
            loadingBuilder:
                (
                  BuildContext context,
                  Widget child,
                  ImageChunkEvent? progress,
                ) {
                  if (progress == null) {
                    return child;
                  }
                  return fallback;
                },
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) => fallback,
          );
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.file(
          File(thumbnailPath),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
          ) => network,
        ),
      );
    }
    return network;
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
}
