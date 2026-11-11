import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_ui/material_ui.dart';

/// 键盘弹起时归零、其余情况取手势条/刘海高度的底部安全区。
///
/// 直接读原始 view 指标，不受 MaterialApp.builder 把 MediaQuery.padding.bottom 置零的影响。
double _bottomInset(BuildContext context) {
  MediaQuery.viewInsetsOf(context);
  final MediaQueryData raw = MediaQueryData.fromView(View.of(context));
  return raw.viewInsets.bottom > 0 ? 0 : raw.viewPadding.bottom;
}

/// 剪贴板检测底部弹窗。
Future<void> showClipboardLinkSheet(
  BuildContext context, {
  required String link,
  required bool autoDetect,
  required ValueChanged<bool> onAutoDetectChanged,
  required VoidCallback onParse,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    // 比默认更慢的 easeOutCubic，弹出更柔和；关闭稍快，避免拖沓。
    sheetAnimationStyle: const AnimationStyle(
      curve: Curves.easeOutCubic,
      duration: Duration(milliseconds: 360),
      reverseCurve: Curves.easeInCubic,
      reverseDuration: Duration(milliseconds: 220),
    ),
    builder: (BuildContext ctx) {
      return _ClipboardSheet(
        link: link,
        autoDetect: autoDetect,
        onAutoDetectChanged: onAutoDetectChanged,
        onParse: onParse,
      );
    },
  );
}

class _ClipboardSheet extends StatefulWidget {
  const _ClipboardSheet({
    required this.link,
    required this.autoDetect,
    required this.onAutoDetectChanged,
    required this.onParse,
  });

  final String link;
  final bool autoDetect;
  final ValueChanged<bool> onAutoDetectChanged;
  final VoidCallback onParse;

  @override
  State<_ClipboardSheet> createState() => _ClipboardSheetState();
}

class _ClipboardSheetState extends State<_ClipboardSheet> {
  late bool _autoDetect = widget.autoDetect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final _PlatformInfo platform = _PlatformInfo.of(widget.link, scheme);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + _bottomInset(context)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '发现一条新链接',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: <Widget>[
                Material(
                  color: platform.color,
                  shape: MaterialShapeBorder(
                    shape: MaterialShapes.cookie9Sided,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Center(
                      child: FaIcon(
                        platform.icon,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        platform.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.link,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '自动检测剪贴板',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '回到应用时自动识别分享链接',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: '自动检测剪贴板',
                child: Switch(
                  value: _autoDetect,
                  onChanged: (bool value) {
                    setState(() => _autoDetect = value);
                    widget.onAutoDetectChanged(value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Tooltip(
                message: '忽略',
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                  child: const Text('忽略'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: '解析这条链接',
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onParse();
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 56),
                      shape: const StadiumBorder(),
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    icon: const Icon(Icons.search),
                    label: const Text('解析这条链接'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlatformInfo {
  const _PlatformInfo(this.title, this.icon, this.color);

  final String title;
  final FaIconData icon;
  final Color color;

  static _PlatformInfo of(String link, ColorScheme scheme) {
    final String lower = link.toLowerCase();
    final bool douyin = lower.contains('douyin') || lower.contains('iesdouyin');
    if (douyin) {
      return const _PlatformInfo(
        '抖音视频',
        FontAwesomeIcons.tiktok,
        Color(0xFF161823),
      );
    }
    return _PlatformInfo('视频链接', FontAwesomeIcons.link, scheme.primary);
  }
}
