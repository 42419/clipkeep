/// 按图片 URL 的来源返回合适的请求头：抖音图床要抖音 Referer，其余用通用 UA。
Map<String, String> imageHeadersFor(String? rawUrl) {
  final String u = (rawUrl ?? '').toLowerCase();
  final bool douyin =
      u.contains('douyin') ||
      u.contains('iesdouyin') ||
      u.contains('douyinpic') ||
      u.contains('bytecdn');
  if (douyin) {
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
