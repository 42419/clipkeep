import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// 通用二次确认弹窗（下载页清空/删除、退出登录共用）。
///
/// 返回 true 表示用户点了确认；关闭遮罩或取消返回 false。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  required String confirmLabel,
  IconData icon = Icons.error_outline,
}) async {
  final bool? confirmed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: title,
      icon: Icon(icon),
      content: Text(content),
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
          tooltip: confirmLabel,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
