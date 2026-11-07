import 'dart:async';
import 'dart:io';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../../components/common/confirm_dialog.dart';
import '../../stores/downloader_store.dart';
import '../../stores/main_tab_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../utils/image_headers.dart';
import '../../viewmodels/download_task.dart';
import '../login/bilibili_login_page.dart';
import '../result_page.dart';

/// 下载页：真实下载任务（进行中 / 已完成）。
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key});

  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  final ScrollController _scroll = ScrollController();
  final M3EDismissibleListController _completedSwipe =
      M3EDismissibleListController();
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
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
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
              child: M3EButtonGroup(
                type: M3EButtonGroupType.connected,
                direction: Axis.horizontal,
                shape: M3EButtonShape.square,
                size: M3EButtonSize.md,
                selectedIndex: tab,
                style: M3EButtonStyle.tonal,
                density: M3EButtonGroupDensity.regular,
                overflow: M3EButtonGroupOverflow.menu,
                // expandedRatio: 0.05,
                spacing: 5,
                onSelectedIndexChanged: (int? index) {
                  if (index != null) {
                    context.read<MainTabController>().selectDownloads(index);
                  }
                },
                actions: <M3EButtonGroupAction>[
                  M3EButtonGroupAction(
                    label: Text('进行中 ${store.activeCount}'),
                    tooltip: '进行中',
                  ),
                  M3EButtonGroupAction(
                    label: Text('已完成 ${store.completedCount}'),
                    tooltip: '已完成',
                  ),
                ],
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
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      children: <Widget>[
                        _buildCompletedList(theme, scheme, store, tasks),
                      ],
                    ),
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
                child: M3EFab(
                  onPressed: () => _confirmClearCompleted(store),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '清空已完成',
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

  Future<void> _openLogin() async {
    final bool? ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => const BilibiliLoginPage(),
      ),
    );
    if (!mounted || ok != true) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(const SnackBar(content: Text('登录成功，可重试下载')));
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
    final String? saved = task.sourceUrl;
    if (saved != null && saved.startsWith('http')) {
      return saved;
    }
    // 兼容旧记录：sourceUrl 曾写成「BV号-cid」，重启后 part 已不在内存里。
    final String? fromSaved = _fromPartId(saved);
    if (fromSaved != null) {
      return fromSaved;
    }
    return _fromPartId(task.part?.id);
  }

  String? _fromPartId(String? id) {
    if (id == null) {
      return null;
    }
    final int idx = id.lastIndexOf('-');
    if (idx <= 0) {
      return null;
    }
    final String head = id.substring(0, idx);
    if (head.startsWith('BV')) {
      return head;
    }
    return int.tryParse(head) == null ? null : 'av$head';
  }

  Widget _buildEmpty(ThemeData theme, ColorScheme scheme, int tab) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            tab == 0 ? Icons.download_outlined : Icons.download_done,
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
              M3EIconButton(
                icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                variant: M3EIconButtonVariant.tonal,
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
              M3EIconButton(
                icon: const Icon(Icons.delete_outline),
                variant: M3EIconButtonVariant.tonal,
                tooltip: '取消并删除',
                onPressed: () => _confirmDeleteTask(store, task),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: M3EProgressIndicator.linearWavy(
              value: task.progress,
              color: scheme.primary,
              trackColor: scheme.surfaceContainerHigh,
              strokeWidth: 4,
              trackStrokeWidth: 4,
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
    final bool needLogin =
        error.contains('登录') ||
        error.contains('-101') ||
        error.contains('HTTP 401') ||
        error.contains('SESSDATA');
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
                      needLogin ? '下载失败 · 需要登录' : '下载失败',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      error,
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
              M3EButton.text(
                onPressed: () => _confirmDeleteTask(store, task),
                size: M3EButtonSize.sm,
                tooltip: '删除记录',
                child: const Text('删除'),
              ),
              const SizedBox(width: 8),
              M3EButton.text(
                onPressed: () => unawaited(store.retryTask(task)),
                size: M3EButtonSize.sm,
                tooltip: '重试',
                child: const Text('重试'),
              ),
              if (needLogin) ...<Widget>[
                const SizedBox(width: 8),
                M3EButton.filled(
                  onPressed: _openLogin,
                  size: M3EButtonSize.sm,
                  icon: const Icon(Icons.login),
                  label: const Text('去登录'),
                  tooltip: '去登录',
                ),
              ],
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
    return M3EList(
      gap: 12,
      itemCount: tasks.length,
      dismissController: _completedSwipe,
      onTap: (int index) => _completedSwipe.reveal(index, leading: false),
      itemBuilder: (BuildContext context, int index) {
        final DownloadTask task = tasks[index];
        return M3EListItem(
          leading: M3EListImage(child: _cover(task, scheme)),
          headline: task.title,
          supportingText:
              '${task.platform} · ${task.qualityLabel} · ${formatBytes(task.totalBytes > 0 ? task.totalBytes : task.receivedBytes)}',
          swipe: M3EListItemSwipe(
            mode: M3EListSwipeMode.reveal,
            edge: M3EListSwipeEdge.end,
            trailing: <M3EListSwipeAction>[
              M3EListSwipeAction(
                icon: const Icon(Icons.refresh),
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                onPressed: () => _reparseTask(store, task),
              ),
              M3EListSwipeAction(
                icon: const Icon(Icons.delete_outline),
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
                isPrimary: true,
                onPressed: () => _confirmDeleteTask(store, task),
              ),
            ],
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
