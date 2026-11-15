import '../constants/app_constants.dart';

/// 接口前缀归一化：空串表示接口在站点根；`clipkeep` 与 `/clipkeep/` 都归一成
/// `/clipkeep`。用 `--base-href /x/` 把整个网关反代到子路径时，构建还要同时传
/// `--dart-define=WEB_API_BASE=/x`，否则请求仍会打到站点根。
String normalizeApiPrefix(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) {
    return '';
  }
  String prefix = value.startsWith('/') ? value : '/$value';
  while (prefix.length > 1 && prefix.endsWith('/')) {
    prefix = prefix.substring(0, prefix.length - 1);
  }
  return prefix == '/' ? '' : prefix;
}

/// web 版的接口根（含端口，不含尾部斜杠）。
String webApiRoot() =>
    '${Uri.base.origin}${normalizeApiPrefix(AppConstants.webApiBase)}';

/// 拼同源接口地址；[path] 必须以 `/` 开头。
Uri webApiUri(String path, [Map<String, String>? query]) {
  final Uri uri = Uri.parse('${webApiRoot()}$path');
  return query == null ? uri : uri.replace(queryParameters: query);
}
