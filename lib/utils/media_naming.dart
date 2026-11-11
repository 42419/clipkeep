import 'dart:convert';

/// 文件名生成规则（与 douyinDLV7 的 content_filename 保持一致）：
/// `日期-类型-作者-标题-分辨率[帧率]-内容ID`，图集为 `日期-图集-作者-标题-内容ID`。
///
/// Android 单个文件名上限是 255 字节（UTF-8），这里按字节截断而不是按字符，
/// 避免中文标题把文件名顶爆后保存失败。
const Set<String> _reservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// 清洗单个文件名片段：去控制字符与 Windows 非法字符，压空白，去首尾点。
String sanitizeNameComponent(
  Object? raw, {
  int limit = 60,
  String fallback = '未命名',
}) {
  String value = (raw ?? '').toString();
  value = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
  value = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  value = value.replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (value.isEmpty) {
    return fallback;
  }
  if (_reservedNames.contains(value.toUpperCase())) {
    value = '_$value';
  }
  value = _takeRunes(value, limit).replaceAll(RegExp(r'[ .]+$'), '');
  return value.isEmpty ? fallback : value;
}

/// 从抖音链接或内容 id 里提取作品 ID（6 位以上数字）。
String contentIdOf(String? raw, {String fallback = 'unknown'}) {
  final String value = (raw ?? '').trim();
  if (value.isEmpty) {
    return fallback;
  }
  final RegExpMatch? number = RegExp(r'\d{6,}').firstMatch(value);
  return number?.group(0) ?? fallback;
}

/// 取日期前缀（`YYYY-MM-DD`）；拿不到就用「未知日期」。
String datePrefix(String? publishedAt) {
  final String value = (publishedAt ?? '').trim();
  if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(value)) {
    return value.substring(0, 10);
  }
  return '未知日期';
}

/// 视频/音频/封面共用的主文件名（不含扩展名与序号后缀）。
String buildVideoStem({
  required String title,
  String? author,
  String? publishedAt,
  String? contentId,
  String? resolution,
  int? fps,
}) {
  final String date = datePrefix(publishedAt);
  final String authorName = sanitizeNameComponent(
    author,
    limit: 30,
    fallback: '未知作者',
  );
  final String safeTitle = sanitizeNameComponent(
    title,
    limit: 50,
    fallback: '无标题',
  );
  final String id = sanitizeNameComponent(
    contentId,
    limit: 30,
    fallback: 'unknown',
  );
  final String quality = (resolution ?? '').trim();
  final String qualityPart = quality.isEmpty ? '' : '-$quality';
  final String fpsPart = fps != null && fps > 0 ? '-${fps}fps' : '';
  return '$date-视频-$authorName-$safeTitle$qualityPart$fpsPart-$id';
}

/// 图集主文件名（不含扩展名）。
String buildAlbumStem({
  required String title,
  String? author,
  String? publishedAt,
  String? contentId,
}) {
  final String date = datePrefix(publishedAt);
  final String authorName = sanitizeNameComponent(
    author,
    limit: 30,
    fallback: '未知作者',
  );
  final String safeTitle = sanitizeNameComponent(
    title,
    limit: 50,
    fallback: '无标题',
  );
  final String id = sanitizeNameComponent(
    contentId,
    limit: 30,
    fallback: 'unknown',
  );
  return '$date-图集-$authorName-$safeTitle-$id';
}

/// 把主文件名 + 后缀拼成最终文件名，超过 [maxBytes] 时按整段截断。
///
/// 截断点在标题末尾，保留后缀（`.mp4`、`-MP.jpg` 等），并用 `…` 标记。
String fitFileName(String stem, String suffix, {int maxBytes = 240}) {
  String clean = stem.replaceAll(RegExp(r'[ .]+$'), '');
  if (clean.isEmpty) {
    clean = '未命名';
  }
  String name = '$clean$suffix';
  if (utf8.encode(name).length <= maxBytes) {
    return name;
  }
  final int suffixBytes = utf8.encode(suffix).length;
  final int budget = maxBytes - suffixBytes - 3; // 3 = '…'
  final StringBuffer buffer = StringBuffer();
  int used = 0;
  for (final int rune in clean.runes) {
    final int bytes = utf8.encode(String.fromCharCode(rune)).length;
    if (used + bytes > budget) {
      break;
    }
    buffer.writeCharCode(rune);
    used += bytes;
  }
  final String head = buffer.toString().replaceAll(RegExp(r'[ .]+$'), '');
  return '${head.isEmpty ? '未命名' : head}…$suffix';
}

String _takeRunes(String value, int limit) {
  final List<int> runes = value.runes.toList();
  if (runes.length <= limit) {
    return value;
  }
  return String.fromCharCodes(runes.take(limit));
}
