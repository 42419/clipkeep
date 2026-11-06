import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// 剪贴板检测底部弹窗（按 Figma「7 剪贴板检测 Clipboard sheet」）。
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
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
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
                M3EShapeContainer(
                  kind: M3EShapeKind.cookie9Sided,
                  height: 56,
                  width: 56,
                  color: platform.color,
                  child: Center(
                    child: FaIcon(platform.icon, color: Colors.white, size: 22),
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
              M3ESwitch(
                value: _autoDetect,
                selectedIcon: const Icon(M3EIcons.check),
                semanticLabel: '自动检测剪贴板',
                onChanged: (bool value) {
                  setState(() => _autoDetect = value);
                  widget.onAutoDetectChanged(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              M3EButton.text(
                onPressed: () => Navigator.of(context).pop(),
                size: M3EButtonSize.md,
                tooltip: '忽略',
                child: const Text('忽略'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: M3EButton.filled(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onParse();
                    },
                    size: M3EButtonSize.md,
                    icon: const Icon(Icons.search),
                    label: const Text('解析这条链接'),
                    tooltip: '解析这条链接',
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
        FontAwesomeIcons.music,
        Color(0xFF161823),
      );
    }
    final bool bili =
        lower.contains('bilibili') ||
        lower.contains('b23.tv') ||
        lower.contains('bili2233') ||
        RegExp(r'BV[0-9A-Za-z]{10}').hasMatch(link);
    if (bili) {
      return const _PlatformInfo(
        '哔哩哔哩视频',
        FontAwesomeIcons.bilibili,
        Color(0xFFF2A0A8),
      );
    }
    return _PlatformInfo('视频链接', FontAwesomeIcons.link, scheme.primary);
  }
}
