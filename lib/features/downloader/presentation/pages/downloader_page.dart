import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../controllers/downloader_controller.dart';
import '../../domain/entities/parsed_source.dart';

/// 下载器主页面：Material 3 Expressive 组件 + 弹簧式入/出场动效。
class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _parse() {
    FocusScope.of(context).unfocus();
    context.read<DownloaderController>().parse(_input.text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DownloaderController>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: M3EAppBar.top(
        titleText: 'ClipKeep',
        subtitleText: 'B站视频下载',
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            M3ETextField(
              controller: _input,
              label: 'B站链接或 BV 号',
              placeholder: '粘贴分享链接或 BV 号',
              leading: const Icon(Icons.link),
              showClearButton: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _parse(),
            ),
            const SizedBox(height: 12),
            M3EButton(
              onPressed: _parse,
              enabled: !controller.parsing,
              icon: const Icon(Icons.search),
              label: Text(controller.parsing ? '解析中…' : '解析'),
              style: M3EButtonStyle.filled,
            ),
            // 解析中：波浪加载，高度平滑展开/收起。
            AnimatedSize(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: controller.parsing
                  ? const Padding(
                      padding: EdgeInsets.only(top: 20, bottom: 4),
                      child: Center(
                        child: M3EProgressIndicator.circularWavy(
                          strokeWidth: 4,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            // 状态切换（空/错误/结果）用淡入+缩放过渡。
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 360),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> animation) {
                final scale = Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                );
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: scale, child: child),
                );
              },
              child: _buildState(context, controller, theme, scheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildState(
    BuildContext context,
    DownloaderController controller,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    if (controller.error != null) {
      return Padding(
        key: const ValueKey<String>('error'),
        padding: const EdgeInsets.only(top: 20),
        child: M3ECard(
          variant: M3ECardVariant.filled,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Icon(Icons.error_outline, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    controller.error!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (controller.source == null) {
      return const _EmptyState(key: ValueKey<String>('empty'));
    }
    return _buildResult(context, controller, theme, scheme);
  }

  Widget _buildResult(
    BuildContext context,
    DownloaderController controller,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final source = controller.source!;
    return Column(
      key: ValueKey<String>('source-${source.title}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 20),
        _Reveal(
          delay: 0,
          child: M3ECard(
            variant: M3ECardVariant.elevated,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (source.coverUrl != null && source.coverUrl!.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Image.network(
                          source.coverUrl!,
                          fit: BoxFit.cover,
                          frameBuilder: (context, child, frame, wasSync) {
                            if (wasSync) {
                              return child;
                            }
                            return AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.easeOut,
                              child: child,
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    source.title,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Icon(Icons.person_outline,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          source.author.isEmpty ? '未知作者' : source.author,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _Reveal(
          delay: 60,
          child: Row(
            children: <Widget>[
              Text(
                '分P',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${source.parts.length} 个',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        ...List<Widget>.generate(source.parts.length, (int i) {
          final part = source.parts[i];
          final video = part.pickVideo();
          final quality = video == null ? '无可用视频流' : qualityLabel(video.quality);
          final codec = video == null ? '' : video.codec.toUpperCase();
          final duration = _formatDuration(part.durationSeconds);
          return _Reveal(
            delay: 120 + i * 70,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: M3ECard(
                variant: M3ECardVariant.filled,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              part.title.isEmpty ? '视频' : part.title,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: <Widget>[
                                _MetaPill(text: quality, scheme: scheme),
                                if (codec.isNotEmpty)
                                  _MetaPill(text: codec, scheme: scheme),
                                if (duration.isNotEmpty)
                                  Text(
                                    duration,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      M3EIconButton(
                        icon: const Icon(Icons.download),
                        tooltip: '下载',
                        variant: M3EIconButtonVariant.filled,
                        onPressed: controller.downloading
                            ? null
                            : () => controller.download(part),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: controller.downloading
              ? Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            begin: 0, end: controller.progress),
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.easeOut,
                        builder: (context, double value, _) {
                          return M3EProgressIndicator.linearWavy(
                            value: value,
                            linearSize: M3EProgressIndicatorSize.s,
                            strokeWidth: 4,
                            trackStrokeWidth: 4,
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '下载中 ${(controller.progress * 100).toStringAsFixed(0)}%',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: controller.savedMessage != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.check_circle, color: scheme.primary, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          controller.savedMessage!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.primary),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds <= 0) {
      return '';
    }
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = secs.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString()}:$mm:$ss';
    }
    return '$mm:$ss';
  }
}

/// 弹簧式入场：淡入 + 上移 + 轻微回弹缩放，可按 index 交错。
class _Reveal extends StatefulWidget {
  const _Reveal({required this.child, this.delay = 0});

  final Widget child;
  final int delay;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 540),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<double> _move =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
  late final Animation<double> _pop =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double dy = (1 - _move.value) * 30;
        final double scale = 0.94 + 0.06 * _pop.value;
        return Opacity(
          opacity: _fade.value,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 空状态：更友好的引导。
class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: Column(
        children: <Widget>[
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(Icons.video_library_outlined,
                size: 44, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 18),
          Text(
            '粘贴链接，开始收藏',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '支持 B 站视频链接、BV 号与分享文案',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 小标签：清晰度/编码。
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, required this.scheme});

  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}
