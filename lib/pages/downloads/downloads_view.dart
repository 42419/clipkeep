import 'dart:io';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../../stores/downloader_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../viewmodels/download_task.dart';

/// 下载页：真实下载任务（进行中 / 已完成）。
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key});

  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DownloaderStore store = context.watch<DownloaderStore>();
    final List<DownloadTask> tasks =
        _tab == 0 ? store.activeTasks : store.completedTasks;
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
                selectedIndex: _tab,
                style: M3EButtonStyle.tonal,
                density: M3EButtonGroupDensity.regular,
                overflow: M3EButtonGroupOverflow.menu,
                // expandedRatio: 0.05,
                spacing: 5,
                onSelectedIndexChanged: (int? index) {
                  if (index != null) {
                    setState(() => _tab = index);
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
                  ? _buildEmpty(theme, scheme)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (BuildContext context, int index) {
                        final DownloadTask task = tasks[index];
                        if (_tab == 0) {
                          return task.isFailed
                              ? _buildErrorCard(theme, scheme, store, task)
                              : _buildActiveCard(theme, scheme, store, task);
                        }
                        return _buildCompletedCard(theme, scheme, store, task);
                      },
                    ),
            ),
          ],
        ),
      ),
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
          M3EIconButton(
            icon: const Icon(Icons.delete_outline),
            variant: M3EIconButtonVariant.tonal,
            tooltip: '清空已完成',
            onPressed: () => _confirmClearCompleted(store),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearCompleted(DownloaderStore store) async {
    final bool? confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: '清空已完成记录？',
        icon: const Icon(M3EIcons.error),
        content: const Text('只删除下载记录，不会删除已保存到相册或下载目录的文件。'),
        actions: <Widget>[
          M3EButton.text(
            onPressed: () => Navigator.of(context).pop(false),
            size: M3EButtonSize.md,
            tooltip: '取消',
            child: const Text('取消'),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.of(context).pop(true),
            size: M3EButtonSize.md,
            tooltip: '清空',
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      store.clearCompleted();
    }
  }

  Widget _buildEmpty(ThemeData theme, ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            _tab == 0 ? Icons.download_outlined : Icons.download_done,
            size: 56,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            _tab == 0 ? '暂无进行中的下载' : '还没有已完成下载',
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
                onPressed: () => paused
                    ? store.resumeTask(task)
                    : store.pauseTask(task),
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
    final bool needLogin = error.contains('登录') || error.contains('-101');
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
                onPressed: () => store.retryTask(task),
                size: M3EButtonSize.sm,
                tooltip: '重试',
                child: const Text('重试'),
              ),
              const SizedBox(width: 8),
              M3EButton.filled(
                onPressed: () {
                  final ScaffoldMessengerState messenger =
                      ScaffoldMessenger.of(context);
                  messenger.clearSnackBars();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('登录功能开发中')),
                  );
                },
                size: M3EButtonSize.sm,
                icon: const Icon(Icons.login),
                label: Text(needLogin ? '去登录' : '查看'),
                tooltip: needLogin ? '去登录' : '查看',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedCard(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
    DownloadTask task,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
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
          M3EIconButton(
            icon: const Icon(Icons.delete_outline),
            variant: M3EIconButtonVariant.standard,
            tooltip: '删除',
            onPressed: () => store.removeTask(task),
          ),
        ],
      ),
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
      child: Icon(
        Icons.play_arrow,
        color: scheme.onPrimaryContainer,
        size: 26,
      ),
    );
    final String? url = _normalizeUrl(task.coverUrl);
    final Widget network = url == null
        ? fallback
        : Image.network(
            url,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            headers: _imageHeaders,
            loadingBuilder: (
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
            ) =>
                fallback,
          );
    final String? local = task.thumbnailPath;
    if (local != null && local.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.file(
          File(local),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
          ) =>
              ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: network,
          ),
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

  String _statsText(DownloadTask task) {
    final List<String> parts = <String>[];
    if (task.totalBytes > 0) {
      parts.add('${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalBytes)}');
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
