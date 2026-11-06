import 'dart:async';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../stores/auth_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/webview_cookies.dart';

/// 哔哩哔哩登录页：官方 WebView 加载 H5 登录页，原生 CookieManager 读取 Cookie。
class BilibiliLoginPage extends StatefulWidget {
  const BilibiliLoginPage({super.key});

  /// 官方登录页（支持扫码 / 密码 / 短信）。
  static const String loginUrl =
      'https://passport.bilibili.com/h5-app/passport/login'
      '?gourl=https://m.bilibili.com/';

  @override
  State<BilibiliLoginPage> createState() => _BilibiliLoginPageState();
}

class _BilibiliLoginPageState extends State<BilibiliLoginPage> {
  static const MethodChannel _cookieChannel = MethodChannel(
    'clipkeep/webview_cookie',
  );
  static const List<String> _cookieKeys = <String>[
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  ];
  static const List<String> _cookieUrls = <String>[
    'https://www.bilibili.com',
    'https://bilibili.com',
    'https://passport.bilibili.com',
    'https://api.bilibili.com',
    'https://m.bilibili.com',
  ];

  late final WebViewController _web;
  Timer? _poll;
  String _currentUrl = BilibiliLoginPage.loginUrl;
  String? _cookie;
  bool _detected = false;
  bool _pageReady = false;
  bool _saving = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) {
              setState(() => _currentUrl = url);
            }
            unawaited(_syncNavigation());
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() => _currentUrl = url);
            }
            unawaited(_syncNavigation());
            unawaited(_checkCookies());
          },
        ),
      );
    // 先清掉旧的 WebView Cookie，否则旧会话会被立刻检测到，无法切换账号。
    unawaited(_loadLoginPage());
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_syncUrl());
      unawaited(_syncNavigation());
      unawaited(_checkCookies());
    });
  }

  Future<void> _loadLoginPage() async {
    await clearWebViewCookies();
    if (!mounted) {
      return;
    }
    await _web.loadRequest(Uri.parse(BilibiliLoginPage.loginUrl));
    if (!mounted) {
      return;
    }
    // 清理完成前不检测 Cookie，否则可能把上一次会话当成刚登录。
    _pageReady = true;
  }

  Future<void> _syncNavigation() async {
    try {
      final bool back = await _web.canGoBack();
      final bool forward = await _web.canGoForward();
      if (!mounted) {
        return;
      }
      if (back != _canGoBack || forward != _canGoForward) {
        setState(() {
          _canGoBack = back;
          _canGoForward = forward;
        });
      }
    } catch (_) {
      // 忽略。
    }
  }

  Future<void> _syncUrl() async {
    try {
      final String? url = await _web.currentUrl();
      if (!mounted || url == null) {
        return;
      }
      if (url != _currentUrl) {
        setState(() => _currentUrl = url);
      }
    } catch (_) {
      // 读取失败忽略。
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _checkCookies() async {
    if (!mounted || _detected || !_pageReady) {
      return;
    }
    final Map<String, String> cookies = await _collectCookies();
    final String? sess = cookies['SESSDATA'];
    if (sess == null || sess.isEmpty) {
      return;
    }
    final List<String> parts = <String>[];
    for (final String key in _cookieKeys) {
      final String? value = cookies[key];
      if (value != null && value.isNotEmpty) {
        parts.add('$key=$value');
      }
    }
    _cookie = parts.join('; ');
    _poll?.cancel();
    unawaited(_flushCookies());
    if (mounted) {
      setState(() => _detected = true);
    }
  }

  Future<Map<String, String>> _collectCookies() async {
    final Map<String, String> out = <String, String>{};
    for (final String url in _cookieUrls) {
      try {
        final String? raw = await _cookieChannel.invokeMethod<String>(
          'getCookie',
          <String, String>{'url': url},
        );
        if (raw == null || raw.isEmpty) {
          continue;
        }
        for (final String part in raw.split(';')) {
          final String item = part.trim();
          final int eq = item.indexOf('=');
          if (eq <= 0) {
            continue;
          }
          final String key = item.substring(0, eq).trim();
          if (_cookieKeys.contains(key)) {
            out[key] = item.substring(eq + 1).trim();
          }
        }
      } catch (_) {
        // 某个域读取失败忽略。
      }
    }
    return out;
  }

  Future<void> _flushCookies() async {
    try {
      await _cookieChannel.invokeMethod<void>('flush');
    } catch (_) {
      // 忽略。
    }
  }

  Future<void> _save() async {
    final String? cookie = _cookie;
    if (cookie == null || _saving) {
      return;
    }
    setState(() => _saving = true);
    final AuthStore auth = context.read<AuthStore>();
    final bool ok = await auth.loginWithCookie(cookie);
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('登录校验失败，请重试或重新登录')));
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_checkCookies());
      });
      setState(() => _detected = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        unawaited(_web.goBack().then((_) => _syncNavigation()));
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        resizeToAvoidBottomInset: false,
        appBar: M3EAppBar.top(
          leading: M3EIconButton(
            icon: const Icon(Icons.close),
            variant: M3EIconButtonVariant.standard,
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          titleText: '登录哔哩哔哩',
          actions: <Widget>[
            M3EIconButton(
              icon: const Icon(Icons.arrow_back),
              variant: M3EIconButtonVariant.standard,
              tooltip: '后退',
              onPressed: _canGoBack ? () => _web.goBack() : null,
            ),
            M3EIconButton(
              icon: const Icon(Icons.arrow_forward),
              variant: M3EIconButtonVariant.standard,
              tooltip: '前进',
              onPressed: _canGoForward ? () => _web.goForward() : null,
            ),
            M3EIconButton(
              icon: const Icon(Icons.refresh),
              variant: M3EIconButtonVariant.standard,
              tooltip: '刷新',
              onPressed: () => _web.reload(),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _currentUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: WebViewWidget(controller: _web)),
              _buildBottomCard(theme, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomCard(ThemeData theme, ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        20 + M3ESafeArea.bottomOf(context),
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.verified_user_outlined,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '登录成功后自动获取 Cookie',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '仅保存在本机，用于解析高清画质，不会上传',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          M3EProgressIndicator.linearWavy(
            value: _detected ? 1 : 0.35,
            color: scheme.primary,
            trackColor: scheme.surfaceContainerHigh,
            strokeWidth: 4,
            trackStrokeWidth: 4,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _detected ? '已检测到登录状态（SESSDATA），可保存' : '正在检测登录状态（SESSDATA）…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              M3EButton.text(
                onPressed: () => Navigator.of(context).pop(false),
                size: M3EButtonSize.md,
                tooltip: '取消',
                child: const Text('取消'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: M3EButton.filled(
                  onPressed: _detected && !_saving ? _save : null,
                  enabled: _detected && !_saving,
                  size: M3EButtonSize.md,
                  icon: const Icon(Icons.check),
                  label: Text(_saving ? '保存中…' : '完成并保存 Cookie'),
                  tooltip: '完成并保存 Cookie',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
