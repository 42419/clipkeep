import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../components/common/confirm_dialog.dart';
import '../../components/common/swipe_reveal.dart';
import '../../stores/downloader_store.dart';
import '../../stores/main_tab_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../utils/image_headers.dart';
import '../../utils/result.dart';
import '../../viewmodels/download_task.dart';
import '../result_page.dart';

/// 下载页：真实下载任务（进行中 / 已完成）。
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key});

  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  final ScrollController _scroll = ScrollController();
  final SwipeRevealController _completedSwipe = SwipeRevealController();
  bool _showClearFab = true;
  bool _openingResult = false;
  double _lastOffset = 0;
  int _lastSection = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _completedSwipe.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    // 滚动时收起已展开的操作，避免滑出状态跟着列表跑。
    if (_completedSwipe.openIndex != null) {
      _completedSwipe.close();
    }
    final double offset = _scroll.offset;
    if (offset <= 0) {
      _setFab(true);
    } else if (offset - _lastOffset > 4) {
      _setFab(false);
    } else if (_lastOffset - offset > 4) {
      _setFab(true);
    }
    _lastOffset = offset;
  }

  void _setFab(bool visible) {
    if (_showClearFab != visible) {
      setState(() => _showClearFab = visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DownloaderStore store = context.watch<DownloaderStore>();
    final MainTabController tabs = context.watch<MainTabController>();
    final int tab = tabs.downloadsSection;
    if (tab != _lastSection) {
      _lastSection = tab;
      _showClearFab = true;
      _lastOffset = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
    final List<DownloadTask> tasks = tab == 0
        ? store.activeTasks
        : store.completedTasks;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildHeader(theme, scheme, store),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: <ButtonSegment<int>>[
                    ButtonSegment<int>(
                      value: 0,
                      label: Text('进行中 ${store.activeCount}'),
                      tooltip: '进行中',
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      label: Text('已完成 ${store.completedCount}'),
                      tooltip: '已完成',
                    ),
                  ],
                  selected: <int>{tab},
                  onSelectionChanged: (Set<int> selection) {
                    if (selection.isEmpty) {
                      return;
                    }
                    context.read<MainTabController>().selectDownloads(
                      selection.first,
                    );
                  },
                  showSelectedIcon: false,
                  // 连体、外侧半圆、选中 secondary / 未选中 secondaryContainer。
                  style: ButtonStyle(
                    minimumSize: const WidgetStatePropertyAll<Size>(
                      Size(0, 48),
                    ),
                    textStyle: WidgetStatePropertyAll<TextStyle?>(
                      theme.textTheme.titleSmall,
                    ),
                    shape: const WidgetStatePropertyAll<OutlinedBorder>(
                      StadiumBorder(),
                    ),
                    side: const WidgetStatePropertyAll<BorderSide?>(
                      BorderSide.none,
                    ),
                    backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                      (Set<WidgetState> states) =>
                          states.contains(WidgetState.selected)
                          ? scheme.secondary
                          : scheme.secondaryContainer,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                      (Set<WidgetState> states) =>
                          states.contains(WidgetState.selected)
                          ? scheme.onSecondary
                          : scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: tasks.isEmpty
                  ? _buildEmpty(theme, scheme, tab)
                  : tab == 0
                  ? ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (BuildContext context, int index) {
                        final DownloadTask task = tasks[index];
                        return task.isFailed
                            ? _buildErrorCard(theme, scheme, store, task)
                            : _buildActiveCard(theme, scheme, store, task);
                      },
                    )
                  : _buildCompletedList(theme, scheme, store, tasks),
            ),
          ],
        ),
      ),
      floatingActionButton: tab == 1 && store.completedCount > 0
          ? AnimatedSlide(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              offset: _showClearFab ? Offset.zero : const Offset(0, 1.5),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                opacity: _showClearFab ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !_showClearFab,
                  child: ExcludeSemantics(
                    excluding: !_showClearFab,
                    child: Tooltip(
                      message: '清空已完成',
                      child: FloatingActionButton(
                        onPressed: () => _confirmClearCompleted(store),
                        child: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildHeader(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '下载',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearCompleted(DownloaderStore store) async {
    final bool ok = await showConfirmDialog(
      context,
      title: '清空已完成记录？',
      content: '只删除下载记录，不会删除已保存到相册或下载目录的文件。',
      confirmLabel: '清空',
    );
    if (ok) {
      unawaited(store.clearCompleted());
    }
  }

  Future<void> _confirmDeleteTask(
    DownloaderStore store,
    DownloadTask task,
  ) async {
    final bool active = !task.isCompleted;
    final bool ok = await showConfirmDialog(
      context,
      title: active ? '取消并删除这条下载？' : '删除这条记录？',
      content: active
          ? '将停止下载并删除记录与临时文件，不会删除已经保存到相册或下载目录的文件。'
          : '只删除下载记录与临时文件，不会删除已保存到相册或下载目录的文件。',
      confirmLabel: '删除',
    );
    if (ok) {
      store.removeTask(task);
    }
  }

  Future<void> _openTask(DownloaderStore store, DownloadTask task) async {
    final Result<String> result = await store.openTask(task);
    if (!mounted) {
      return;
    }
    if (result is Err<String>) {
      _toast(result.error.message);
    }
  }

  Future<void> _shareTask(DownloaderStore store, DownloadTask task) async {
    final Result<String> result = await store.shareTask(task);
    if (!mounted) {
      return;
    }
    if (result is Err<String>) {
      _toast(result.error.message);
    }
  }

  void _toast(String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reparseTask(DownloaderStore store, DownloadTask task) async {
    if (_openingResult) {
      return;
    }
    final String? input = _taskInput(task);
    if (input == null) {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('无法重新解析该记录')));
      return;
    }
    _openingResult = true;
    try {
      unawaited(store.parse(input));
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const ResultPage(),
        ),
      );
    } finally {
      _openingResult = false;
    }
  }

  String? _taskInput(DownloadTask task) {
    for (final String? candidate in <String?>[task.sourceUrl, task.part?.id]) {
      final String? url = _douyinUrl(candidate);
      if (url != null) {
        return url;
      }
    }
    return null;
  }

  /// 把保存的地址或裸 aweme_id 还原成可重新解析的抖音作品页。
  String? _douyinUrl(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.startsWith('http')) {
      return value;
    }
    return RegExp(r'^\d{15,}$').hasMatch(value)
        ? 'https://www.douyin.com/video/$value'
        : null;
  }

  Widget _buildEmpty(ThemeData theme, ColorScheme scheme, int tab) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            tab == 0 ? Icons.download_rounded : Icons.download_done_rounded,
            size: 56,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            tab == 0 ? '暂无进行中的下载' : '还没有已完成下载',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveCard(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
    DownloadTask task,
  ) {
    final bool paused = task.status == DownloadStatus.paused;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              _cover(task, scheme),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${task.platform} · ${task.qualityLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                icon: Icon(
                  paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                ),
                tooltip: paused ? '继续' : '暂停',
                onPressed: () {
                  if (paused) {
                    unawaited(store.resumeTask(task));
                  } else {
                    store.pauseTask(task);
                  }
                },
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: '取消并删除',
                onPressed: () => _confirmDeleteTask(store, task),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: LinearProgressIndicator(
              value: task.progress,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHigh,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _statsText(task),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
    DownloadTask task,
  ) {
    final String error = task.error ?? '下载失败';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '下载失败',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.phase ?? error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Tooltip(
                message: '删除记录',
                child: TextButton(
                  onPressed: () => _confirmDeleteTask(store, task),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: const Text('删除'),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '重试',
                child: TextButton(
                  onPressed: () => unawaited(store.retryTask(task)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: const Text('重试'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedList(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
    List<DownloadTask> tasks,
  ) {
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: tasks.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) {
        final DownloadTask task = tasks[index];
        return SwipeRevealItem(
          controller: _completedSwipe,
          index: index,
          borderRadius: AppTheme.radiusMd,
          actions: <Widget>[
            if (task.savedNames.isNotEmpty) ...<Widget>[
              SwipeRevealAction(
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                icon: Icons.open_in_new,
                tooltip: '打开',
                onPressed: () {
                  _completedSwipe.close();
                  unawaited(_openTask(store, task));
                },
              ),
              SwipeRevealAction(
                backgroundColor: scheme.tertiaryContainer,
                foregroundColor: scheme.onTertiaryContainer,
                icon: Icons.share_outlined,
                tooltip: '分享',
                onPressed: () {
                  _completedSwipe.close();
                  unawaited(_shareTask(store, task));
                },
              ),
            ],
            SwipeRevealAction(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
              icon: Icons.refresh,
              tooltip: '重新解析',
              onPressed: () {
                _completedSwipe.close();
                unawaited(_reparseTask(store, task));
              },
            ),
            SwipeRevealAction(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
              icon: Icons.delete_outline,
              tooltip: '删除记录',
              onPressed: () {
                _completedSwipe.close();
                unawaited(_confirmDeleteTask(store, task));
              },
            ),
          ],
          child: Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _completedSwipe.toggle(index),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    _cover(task, scheme),
                    const SizedBox(width: 14),
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
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
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
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _cover(DownloadTask task, ColorScheme scheme) {
    final Widget fallback = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Icon(Icons.play_arrow, color: scheme.onPrimaryContainer, size: 26),
    );
    final String? url = _normalizeUrl(task.coverUrl);
    final Widget network = url == null
        ? fallback
        : Image.network(
            url,
            width: 56,
            height: 56,
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
    final String? local = task.thumbnailPath;
    final Widget image = (local != null && local.isNotEmpty)
        ? Image.file(
            File(local),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            errorBuilder: (
              BuildContext context,
              Object error,
              StackTrace? stackTrace,
            ) => network,
          )
        : network;
    return ClipRRect(borderRadius: BorderRadius.circular(18), child: image);
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

  String _statsText(DownloadTask task) {
    if (task.status == DownloadStatus.queued) {
      return '排队中…';
    }
    final String? phase = task.phase;
    if (phase != null && phase.isNotEmpty) {
      return phase;
    }
    final List<String> parts = <String>[
      if (task.status == DownloadStatus.paused) '已暂停',
    ];
    if (task.totalBytes > 0) {
      parts.add(
        '${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalBytes)}',
      );
    } else {
      parts.add(formatBytes(task.receivedBytes));
    }
    parts.add(formatSpeed(task.speedBytesPerSec));
    if (task.speedBytesPerSec > 0 &&
        task.totalBytes > task.receivedBytes &&
        task.status == DownloadStatus.downloading) {
      final int eta =
          ((task.totalBytes - task.receivedBytes) / task.speedBytesPerSec)
              .round();
      parts.add('剩余 ${formatEta(eta)}');
    }
    return parts.join(' · ');
  }
}
