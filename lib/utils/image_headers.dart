import 'package:flutter/foundation.dart' show kIsWeb;

import 'web_api.dart';

/// 抖音图床域名（含子域）。判断按 host 后缀做，不看整条 URL：
/// `https://evil.com/douyin.jpg` 里的 "douyin" 不能算数。
const Set<String> _douyinImageHosts = <String>{
  'douyin.com',
  'iesdouyin.com',
  'douyinpic.com',
  'douyincdn.com',
  'douyinstatic.com',
  'bytecdn.cn',
  'byteimg.com',
};

/// 是不是抖音图床的链接。
bool isDouyinImageUrl(String? rawUrl) {
  final Uri? uri = Uri.tryParse((rawUrl ?? '').trim());
  final String host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty) {
    return false;
  }
  for (final String suffix in _douyinImageHosts) {
    if (host == suffix || host.endsWith('.$suffix')) {
      return true;
    }
  }
  return false;
}

/// 按图片 URL 的来源返回合适的请求头：抖音图床要抖音 Referer，其余用通用 UA。
///
/// 只对原生端有效。网页端浏览器禁止脚本设置 `user-agent` / `referer`，
/// 显示图片请改用 [displayImageUrl] 与 [displayImageHeaders]。
Map<String, String> imageHeadersFor(String? rawUrl) {
  if (isDouyinImageUrl(rawUrl)) {
    return const <String, String>{
      'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'referer': 'https://www.douyin.com/',
    };
  }
  return const <String, String>{
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };
}

/// 把抖音图床链接改写成网关的同源中转地址：`<apiRoot>/img?u=<原链接>`。
///
/// 纯函数，方便单测；[apiRoot] 不含尾部斜杠。
String gatewayImageUrl(String url, {required String apiRoot}) =>
    Uri.parse('$apiRoot/img').replace(queryParameters: {'u': url}).toString();

/// 供 `Image.network` 显示用的地址。
///
/// 网页端直连抖音图床不可靠：带 `headers` 时 Flutter 会改用 XHR 拉字节，要求 CDN 返回
/// CORS 头，而 `referer` 又被浏览器丢掉，iOS Safari 上封面与头像会整批加载失败。
/// 所以网页端的抖音图片统一走网关 `/img` 中转；原生端与非抖音图片保持直连。
String displayImageUrl(String url) {
  if (kIsWeb && isDouyinImageUrl(url)) {
    return gatewayImageUrl(url, apiRoot: webApiRoot());
  }
  return url;
}

/// 供 `Image.network` 显示用的请求头。
///
/// 网页端返回 null：同源的 `/img` 不需要任何自定义头，也避免 Flutter 因为
/// 带了 `headers` 而改走 XHR 路径。
Map<String, String>? displayImageHeaders(String url) =>
    kIsWeb ? null : imageHeadersFor(url);
