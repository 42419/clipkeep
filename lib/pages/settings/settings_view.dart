import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../../constants/app_constants.dart';
import '../../stores/auth_store.dart';
import '../../stores/settings_store.dart';
import '../../theme/app_theme.dart';
import '../login/bilibili_login_page.dart';

/// 设置页：账号 / 下载 / 外观与关于。
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AuthStore auth = context.watch<AuthStore>();
    final SettingsStore settings = context.watch<SettingsStore>();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: <Widget>[
            Text(
              '设置',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel(theme, scheme, '账号'),
            const SizedBox(height: 10),
            _biliCard(context, theme, scheme, auth),
            const SizedBox(height: 8),
            _douyinCard(theme, scheme),
            const SizedBox(height: 24),
            _sectionLabel(theme, scheme, '下载'),
            const SizedBox(height: 10),
            M3EList(
              itemCount: 2,
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) {
                  return M3EListItem(
                    leading: const Icon(Icons.folder_rounded),
                    headline: '保存位置',
                    supportingText: settings.saveToGallery
                        ? '相册 · ${AppConstants.albumName}'
                        : '下载 / ClipKeep',
                    trailing: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                    onTap: () => _showSaveLocation(context, settings),
                  );
                }
                return M3EListItem(
                  leading: const Icon(Icons.image_rounded),
                  headline: '下载后保存到相册',
                  supportingText: '完成后自动写入系统相册',
                  trailing: M3ESwitch(
                    value: settings.saveToGallery,
                    selectedIcon: const Icon(M3EIcons.check),
                    semanticLabel: '下载后保存到相册',
                    onChanged: (bool v) => settings.setSaveToGallery(v),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            _sectionLabel(theme, scheme, '外观与关于'),
            const SizedBox(height: 10),
            M3EList(
              itemCount: 2,
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) {
                  return M3EListItem(
                    leading: const Icon(Icons.palette_rounded),
                    headline: '动态取色',
                    supportingText: '跟随系统壁纸生成主题色',
                    trailing: M3ESwitch(
                      value: settings.dynamicColor,
                      selectedIcon: const Icon(M3EIcons.check),
                      semanticLabel: '动态取色',
                      onChanged: (bool v) => settings.setDynamicColor(v),
                    ),
                  );
                }
                return M3EListItem(
                  leading: const Icon(Icons.description_rounded),
                  headline: '开源许可',
                  supportingText: '第三方组件与来源声明',
                  trailing: Icon(
                    Icons.chevron_right,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () => _showLicenses(context),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, ColorScheme scheme, String text) {
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: scheme.primary,
      ),
    );
  }

  Widget _biliCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    AuthStore auth,
  ) {
    final bool loggedIn = auth.isLoggedIn;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _biliAvatar(auth),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '哔哩哔哩',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _biliSubtitle(auth),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _pill(
                theme,
                scheme,
                loggedIn ? '已登录' : '未登录',
                bg: loggedIn
                    ? scheme.tertiaryContainer
                    : scheme.surfaceContainerHighest,
                fg: loggedIn
                    ? scheme.onTertiaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              if (loggedIn)
                M3EButton.text(
                  onPressed: () => _confirmLogout(context, auth),
                  size: M3EButtonSize.sm,
                  tooltip: '退出登录',
                  child: const Text('退出登录'),
                ),
              const Spacer(),
              M3EButton.filled(
                onPressed: () => _openLogin(context),
                size: M3EButtonSize.sm,
                icon: const Icon(Icons.login),
                label: Text(loggedIn ? '重新登录（WebView）' : '登录（WebView）'),
                tooltip: '打开 WebView 登录',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _biliSubtitle(AuthStore auth) {
    if (!auth.isLoggedIn) {
      return '未登录 · 仅支持 480P 及以下';
    }
    final DateTime? expires = auth.cookieExpiresAt;
    if (expires == null) {
      return '已登录 · 高清画质已解锁';
    }
    final String y = expires.year.toString().padLeft(4, '0');
    final String m = expires.month.toString().padLeft(2, '0');
    final String d = expires.day.toString().padLeft(2, '0');
    return '已登录 · Cookie 有效至 $y-$m-$d';
  }

  Widget _biliAvatar(AuthStore auth) {
    final String face = auth.face ?? '';
    final Widget fallback = Container(
      width: 56,
      height: 56,
      decoration: const BoxDecoration(
        color: Color(0xFFF2A0A8),
        shape: BoxShape.circle,
      ),
      child: const Center(
        child: FaIcon(FontAwesomeIcons.bilibili, color: Colors.white, size: 24),
      ),
    );
    if (face.isEmpty) {
      return fallback;
    }
    return ClipOval(
      child: SizedBox(
        width: 56,
        height: 56,
        child: Image.network(
          face,
          fit: BoxFit.cover,
          headers: _imageHeaders,
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
          ) => fallback,
        ),
      ),
    );
  }

  Widget _douyinCard(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Color(0xFF161823),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: FaIcon(
                FontAwesomeIcons.tiktok,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '抖音',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '访客模式 · 无需登录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _pill(
            theme,
            scheme,
            '自动',
            bg: scheme.secondaryContainer,
            fg: scheme.onSecondaryContainer,
          ),
        ],
      ),
    );
  }

  Widget _pill(
    ThemeData theme,
    ColorScheme scheme,
    String text, {
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  void _showSnack(BuildContext context, String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSaveLocation(BuildContext context, SettingsStore settings) {
    _showSnack(
      context,
      settings.saveToGallery
          ? '当前保存到相册（${AppConstants.albumName}）'
          : '当前保存到「下载/ClipKeep」目录',
    );
  }

  Future<void> _openLogin(BuildContext context) async {
    final bool? ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => const BilibiliLoginPage(),
      ),
    );
    if (!context.mounted) {
      return;
    }
    if (ok == true) {
      _showSnack(context, '登录成功，已解锁高清画质');
    }
  }

  Future<void> _confirmLogout(BuildContext context, AuthStore auth) async {
    final bool? confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: '退出哔哩哔哩登录？',
        icon: const Icon(Icons.logout),
        content: const Text('退出后将无法解析和下载高清画质。'),
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
            tooltip: '退出登录',
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await auth.logout();
      if (context.mounted) {
        _showSnack(context, '已退出哔哩哔哩登录');
      }
    }
  }

  Future<void> _showLicenses(BuildContext context) {
    return M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: '开源许可与致谢',
        icon: const Icon(Icons.description_rounded),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              'ClipKeep 使用的开源组件与参考实现：\n\n'
              '• Flutter / Dart（BSD-3-Clause）\n'
              '• FFmpeg / FFmpegKit（LGPL / GPL，视所用变体而定）\n'
              '• PiliPlus（GPL-3.0-or-later）—— 哔哩哔哩接口解析参考实现\n'
              '• bilibili-API-collect（CC-BY-NC 4.0）—— WBI 签名等接口文档\n'
              '• 其余 pub.dev 依赖遵循各自许可证\n\n'
              '本应用与哔哩哔哩无隶属关系，仅供学习研究；请仅下载你有权保存的内容。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        actions: <Widget>[
          M3EButton.text(
            onPressed: () => Navigator.of(context).pop(),
            size: M3EButtonSize.md,
            tooltip: '关闭',
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
