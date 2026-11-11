import 'package:material_ui/material_ui.dart';

/// 通用二次确认弹窗（下载页清空/删除共用）。
///
/// 返回 true 表示用户点了确认；关闭遮罩或取消返回 false。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  required String confirmLabel,
  IconData icon = Icons.error_outline,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        icon: Icon(icon),
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          Tooltip(
            message: '取消',
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ),
          Tooltip(
            message: confirmLabel,
            child: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}
