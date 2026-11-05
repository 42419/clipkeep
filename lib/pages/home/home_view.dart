import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../../stores/auth_store.dart';
import '../../stores/downloader_store.dart';
import '../../stores/main_tab_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../login/bilibili_login_page.dart';
import '../result_page.dart';

/// 首页：按 Figma 设计稿实现。
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  static const Map<String, String> _imageHeaders = <String, String>{
    'referer': 'https://www.bilibili.com/',
    'user-agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
  };

  final TextEditingController _input = TextEditingController();
  int _mode = 0; // 0 自动识别 / 1 抖音 / 2 哔哩哔哩

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _input.text = text);
    }
  }

  Future<void> _parse() async {
    FocusScope.of(context).unfocus();
    final text = _input.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (text.isEmpty) {
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('请先粘贴视频链接')));
      return;
    }
    // 立即跳转，解析在网络请求进行中完成，结果页展示骨架屏。
    final store = context.read<DownloaderStore>();
    unawaited(store.parse(text));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const ResultPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = context.watch<DownloaderStore>();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.pagePadding,
            8,
            AppTheme.pagePadding,
            16,
          ),
          children: <Widget>[
            _buildHeader(theme, scheme),
            const SizedBox(height: AppTheme.gap),
            _buildPasteCard(theme, scheme, controller),
            const SizedBox(height: AppTheme.gap),
            _buildLoginCard(theme, scheme),
            const SizedBox(height: 24),
            _buildRecent(theme, scheme, controller),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'ClipKeep',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '粘贴分享链接，一键保存视频',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          M3EShapeContainer(
            kind: M3EShapeKind.cookie12Sided,
            height: 48,
            width: 48,
            color: scheme.tertiaryContainer,
            child: Icon(
              Icons.download_rounded,
              size: 22,
              color: scheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasteCard(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore controller,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '粘贴视频链接',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 56,
            padding: const EdgeInsets.only(left: 16, right: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.link, size: 22, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _parse(),
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '粘贴分享链接或 BV 号',
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                M3EIconButton(
                  icon: const Icon(Icons.content_paste),
                  variant: M3EIconButtonVariant.filled,
                  tooltip: '粘贴',
                  onPressed: _paste,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          M3EButtonGroup(
            type: M3EButtonGroupType.standard,
            direction: Axis.horizontal,
            shape: M3EButtonShape.square,
            size: M3EButtonSize.sm,
            selectedIndex: _mode,
            style: M3EButtonStyle.filled,
            density: M3EButtonGroupDensity.regular,
            neighborSquish: true,
            expandedRatio: 0.1,
            spacing: 5,
            onSelectedIndexChanged: (index) => setState(() {
              _mode = index!;
            }),
            actions: const <M3EButtonGroupAction>[
              M3EButtonGroupAction(
                icon: Icon(M3EIcons.check),
                label: Text('自动识别'),
                tooltip: '自动识别',
              ),
              M3EButtonGroupAction(
                icon: FaIcon(FontAwesomeIcons.tiktok),
                label: Text('抖音'),
                tooltip: '抖音',
              ),
              M3EButtonGroupAction(
                icon: FaIcon(FontAwesomeIcons.bilibili),
                label: Text('哔哩哔哩'),
                tooltip: '哔哩哔哩',
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: M3EButton(
              onPressed: _parse,
              size: M3EButtonSize.md,
              tooltip: controller.parsing ? '解析中…' : '解析视频',
              enabled: !controller.parsing,
              icon: const Icon(Icons.search),
              label: Text(controller.parsing ? '解析中…' : '解析视频'),
              style: M3EButtonStyle.filled,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginCard(ThemeData theme, ColorScheme scheme) {
    final AuthStore auth = context.watch<AuthStore>();
    if (auth.isLoggedIn) {
      final String uname =
          (auth.uname != null && auth.uname!.isNotEmpty) ? auth.uname! : '已登录';
      final String face = auth.face ?? '';
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: Row(
          children: <Widget>[
            ClipOval(
              child: SizedBox(
                width: 48,
                height: 48,
                child: face.isNotEmpty
                    ? Image.network(
                        face,
                        fit: BoxFit.cover,
                        headers: _imageHeaders,
                        errorBuilder: (
                          BuildContext context,
                          Object error,
                          StackTrace? stackTrace,
                        ) => _biliAvatar(),
                      )
                    : _biliAvatar(),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '哔哩哔哩 · $uname',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    auth.vip ? '大会员 · 高清画质已解锁' : '已登录 · 可解析高清画质',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            M3EButton(
              onPressed: () {
                unawaited(context.read<AuthStore>().logout());
              },
              tooltip: '退出登录',
              label: const Text('退出'),
              size: M3EButtonSize.sm,
              style: M3EButtonStyle.tonal,
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Row(
        children: <Widget>[
          _biliAvatar(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '哔哩哔哩 · 未登录',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '登录后可解析 1080P+ / 会员画质',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          M3EButton(
            onPressed: _openLogin,
            tooltip: '登录',
            icon: const Icon(Icons.login),
            label: const Text('登录'),
            size: M3EButtonSize.sm,
            style: M3EButtonStyle.tonal,
          ),
        ],
      ),
    );
  }

  Widget _biliAvatar() {
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
        color: Color(0xFFF2A0A8),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: FaIcon(
          FontAwesomeIcons.bilibili,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }

  Future<void> _openLogin() async {
    final bool? ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => const BilibiliLoginPage(),
      ),
    );
    if (!mounted) {
      return;
    }
    if (ok == true) {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(content: Text('登录成功，已解锁高清画质')),
      );
    }
  }

  Widget _buildRecent(
    ThemeData theme,
    ColorScheme scheme,
    DownloaderStore store,
  ) {
    final tasks = store.completedTasks.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '最近下载',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              M3EButton.text(
                onPressed: () => context.read<MainTabController>().select(1),
                size: M3EButtonSize.sm,
                tooltip: '查看全部下载',
                child: const Text('全部'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.video_library_outlined,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '还没有下载记录',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '解析并下载后，这里会显示最近的视频',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          for (int i = 0; i < tasks.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            _recentItem(
              theme,
              scheme,
              thumbColor: i.isEven
                  ? scheme.primaryContainer
                  : scheme.tertiaryContainer,
              iconColor: i.isEven
                  ? scheme.onPrimaryContainer
                  : scheme.onTertiaryContainer,
              title: tasks[i].title,
              meta: '${tasks[i].platform} · ${tasks[i].qualityLabel} · ${formatBytes(tasks[i].totalBytes > 0 ? tasks[i].totalBytes : tasks[i].receivedBytes)}',
              coverUrl: tasks[i].coverUrl,
              thumbnailPath: tasks[i].thumbnailPath,
            ),
          ],
      ],
    );
  }

  Widget _recentThumb(
    ColorScheme scheme,
    String? thumbnailPath,
    String? coverUrl,
    Color thumbColor,
    Color iconColor,
  ) {
    final Widget fallback = Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: thumbColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(Icons.play_arrow, color: iconColor, size: 26),
    );
    final String? url = _normalizeUrl(coverUrl);
    final Widget network = url == null
        ? fallback
        : Image.network(
            url,
            width: 60,
            height: 60,
            fit: BoxFit.cover,
            headers: _imageHeaders,
            loadingBuilder: (BuildContext context, Widget child,
                ImageChunkEvent? progress) {
              if (progress == null) {
                return child;
              }
              return fallback;
            },
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stackTrace) =>
                    fallback,
          );
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.file(
          File(thumbnailPath),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) =>
                  network,
        ),
      );
    }
    return network;
  }

  String? _normalizeUrl(String? raw) {
    if (raw == null) {
      return null;
    }
    final String v = raw.trim();
    if (v.isEmpty) {
      return null;
    }
    if (v.startsWith('//')) {
      return 'https:$v';
    }
    if (v.startsWith('http://')) {
      return 'https://${v.substring(7)}';
    }
    if (v.startsWith('https://')) {
      return v;
    }
    return 'https://$v';
  }

  Widget _recentItem(
    ThemeData theme,
    ColorScheme scheme, {
    required Color thumbColor,
    required Color iconColor,
    required String title,
    required String meta,
    String? coverUrl,
    String? thumbnailPath,
  }) {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 12, top: 8, bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          _recentThumb(scheme, thumbnailPath, coverUrl, thumbColor, iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: '更多操作',
            child: Icon(
              Icons.more_vert,
              size: 22,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
