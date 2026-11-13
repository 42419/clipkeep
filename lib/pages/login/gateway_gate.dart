import 'package:material_ui/material_ui.dart';

import '../../api/gateway_session.dart';
import '../../theme/app_theme.dart';
import '../main_page.dart';

/// web 入口闸门：先探一次会话，未登录就停在登录页。
///
/// Android 端不走这里（`app_router` 只在 `kIsWeb` 时挂载）。
class GatewayGate extends StatefulWidget {
  const GatewayGate({super.key, this.session, this.child});

  /// 测试可注入；默认按同源地址自行构造。
  final GatewaySession? session;
  final Widget? child;

  @override
  State<GatewayGate> createState() => _GatewayGateState();
}

class _GatewayGateState extends State<GatewayGate> {
  late final GatewaySession _session = widget.session ?? GatewaySession();

  bool _checking = true;
  bool _authenticated = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final bool authenticated = await _session.isAuthenticated();
    if (!mounted) {
      return;
    }
    setState(() {
      _authenticated = authenticated;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_authenticated) {
      return widget.child ?? const MainPage();
    }
    return GatewayLoginPage(
      session: _session,
      onSuccess: () {
        if (mounted) {
          setState(() => _authenticated = true);
        }
      },
    );
  }
}

/// 输入访问口令换 cookie。口令只在内存里过一遍，不写任何存储。
class GatewayLoginPage extends StatefulWidget {
  const GatewayLoginPage({
    super.key,
    required this.session,
    required this.onSuccess,
  });

  final GatewaySession session;
  final VoidCallback onSuccess;

  @override
  State<GatewayLoginPage> createState() => _GatewayLoginPageState();
}

class _GatewayLoginPageState extends State<GatewayLoginPage> {
  final TextEditingController _input = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    final String token = _input.text.trim();
    if (token.isEmpty) {
      setState(() => _error = '请输入访问口令');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.login(token);
      if (!mounted) {
        return;
      }
      // 口令用完即弃：不留在输入框、不写 localStorage。
      _input.clear();
      widget.onSuccess();
    } on GatewayAuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = '无法连接网关：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.pagePadding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'ClipKeep',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '网页版需要访问口令',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _input,
                    autofocus: true,
                    obscureText: true,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: '访问口令',
                      hintText: '在服务器 .env 里的 SITE_TOKEN',
                      border: const OutlineInputBorder(),
                      errorText: _error,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '登录后凭证由浏览器保存 30 天，口令不会留在本地。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
