import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:provider/provider.dart';

import '../../stores/downloader_store.dart';
import '../../theme/app_theme.dart';
import '../result_page.dart';

/// 首页：按 Figma 设计稿实现。
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
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
      MaterialPageRoute<void>(builder: (BuildContext context) => const ResultPage()),
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
            const SizedBox(height: AppTheme.gap),
            _buildRecent(theme, scheme),
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
            height: 56,
            width: 56,
            color: scheme.tertiaryContainer,
            child: Icon(
              Icons.file_download_outlined,
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
      padding: const EdgeInsets.all(20),
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
          const SizedBox(height: 14),
          Container(
            height: 60,
            padding: const EdgeInsets.only(left: 20, right: 8),
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
                Tooltip(
                  message: '粘贴',
                  child: GestureDetector(
                    onTap: _paste,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Icon(
                        Icons.content_paste,
                        size: 22,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
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
          const SizedBox(height: 14),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Row(
        children: <Widget>[
          // Container(
          //   width: 52,
          //   height: 52,
          //   alignment: Alignment.center,
          //   decoration: const BoxDecoration(
          //     color: Color(0xFFF2A0A8),
          //     shape: BoxShape.circle,
          //   ),
          //   child: const Text(
          //     'B',
          //     style: TextStyle(
          //       color: Colors.white,
          //       fontSize: 22,
          //       fontWeight: FontWeight.w600,
          //     ),
          //   ),
          // ),
          M3EShapeContainer(
            kind: M3EShapeKind.cookie9Sided,
            height: 52,
            width: 52,
            color: Color(0xFFF2A0A8),
            child: Center(
              child: FaIcon(FontAwesomeIcons.bilibili, color: Colors.white),
            ),
          ),
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
            onPressed: () {},
            tooltip: '登录',
            icon: const Icon(Icons.login),
            label: const Text('登录'),
            style: M3EButtonStyle.tonal,
          ),
        ],
      ),
    );
  }

  Widget _buildRecent(ThemeData theme, ColorScheme scheme) {
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
              Tooltip(
                message: '查看全部下载',
                child: TextButton(
                  onPressed: () {},
                  child: Text(
                    '全部',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _recentItem(
          theme,
          scheme,
          thumbColor: scheme.primaryContainer,
          iconColor: scheme.onPrimaryContainer,
          title: '夏日傍晚的海边日落｜延时摄影',
          meta: '抖音 · 1080P · 24.3 MB',
        ),
        const SizedBox(height: 8),
        _recentItem(
          theme,
          scheme,
          thumbColor: scheme.tertiaryContainer,
          iconColor: scheme.onTertiaryContainer,
          title: '【4K】东京夜景漫步 · 雨后的涩谷',
          meta: '哔哩哔哩 · 720P · 61.8 MB',
        ),
      ],
    );
  }

  Widget _recentItem(
    ThemeData theme,
    ColorScheme scheme, {
    required Color thumbColor,
    required Color iconColor,
    required String title,
    required String meta,
  }) {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 12, top: 8, bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: thumbColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.play_arrow, color: iconColor, size: 26),
          ),
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
