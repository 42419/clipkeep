import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../api/dtk_client.dart';
import '../../components/common/confirm_dialog.dart';
import '../../constants/app_constants.dart';
import '../../stores/downloader_store.dart';
import '../../stores/settings_store.dart';
import '../../stores/update_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../utils/result.dart';
import '../update/changelog_page.dart';
import '../update/update_page.dart';

/// 设置页：平台 / 下载 / 外观与关于。
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final SettingsStore settings = context.watch<SettingsStore>();
    final UpdateStore updates = context.watch<UpdateStore>();
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
            _sectionLabel(theme, scheme, '平台'),
            const SizedBox(height: 10),
            _douyinCard(theme, scheme),
            const SizedBox(height: 24),
            // web 版没有本地下载、相册写入和磁盘缓存，整组隐藏。
            if (!kIsWeb) ...[
              _sectionLabel(theme, scheme, '下载'),
              const SizedBox(height: 10),
              _SettingsGroup(
                children: <Widget>[
                  _SettingsTile(
                    icon: Icons.folder_rounded,
                    headline: '保存位置',
                    supportingText: settings.saveToGallery
                        ? '相册 · ${AppConstants.albumName}'
                        : '系统下载目录 · Download/ClipKeep',
                    trailing: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                    onTap: () => _showSaveLocation(context, settings),
                  ),
                  _SettingsTile(
                    icon: Icons.image_rounded,
                    headline: '下载后保存到相册',
                    supportingText: '完成后自动写入系统相册',
                    trailing: _switch(
                      value: settings.saveToGallery,
                      label: '下载后保存到相册',
                      onChanged: settings.setSaveToGallery,
                    ),
                    onTap: () =>
                        settings.setSaveToGallery(!settings.saveToGallery),
                  ),
                  _SettingsTile(
                    icon: Icons.speed_rounded,
                    headline: '同时下载',
                    supportingText: '${settings.maxConcurrent} 个任务，其余排队',
                    trailing: Icon(
                      Icons.chevron_right,
                      color: scheme.onSurfaceVariant,
                    ),
                    onTap: () => _showConcurrency(context, settings),
                  ),
                  const _CacheTile(),
                ],
              ),
              const SizedBox(height: 24),
            ],
            // 浏览器读剪贴板需要用户手势与授权，自动检测在 web 上做不到。
            if (!kIsWeb) ...[
              _sectionLabel(theme, scheme, '剪贴板'),
              const SizedBox(height: 10),
              _SettingsGroup(
                children: <Widget>[
                  _SettingsTile(
                    icon: Icons.content_paste_rounded,
                    headline: '自动检测剪贴板',
                    supportingText: '回到 App 时自动识别复制的分享链接',
                    trailing: _switch(
                      value: settings.clipboardAuto,
                      label: '自动检测剪贴板',
                      onChanged: settings.setClipboardAuto,
                    ),
                    onTap: () =>
                        settings.setClipboardAuto(!settings.clipboardAuto),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
            // web 版由网关持有 DTK 地址与 Key，前端不暴露这一组配置。
            if (!kIsWeb) ...[
              _sectionLabel(theme, scheme, '解析服务（抖音）'),
              const SizedBox(height: 10),
              const _DtkServiceCard(),
              const SizedBox(height: 24),
            ],
            _sectionLabel(theme, scheme, '外观与关于'),
            const SizedBox(height: 10),
            _SettingsGroup(
              children: <Widget>[
                // 动态取色依赖 Android 系统调色板，web 上没有实现。
                if (!kIsWeb)
                  _SettingsTile(
                    icon: Icons.palette_rounded,
                    headline: '动态取色',
                    supportingText: '跟随系统壁纸生成主题色',
                    trailing: _switch(
                      value: settings.dynamicColor,
                      label: '动态取色',
                      onChanged: settings.setDynamicColor,
                    ),
                    onTap: () =>
                        settings.setDynamicColor(!settings.dynamicColor),
                  ),
                // web 版不做 APK 更新（UpdateStore 在 web 上也不检查）。
                if (!kIsWeb)
                  _SettingsTile(
                    icon: Icons.system_update_alt_rounded,
                    headline: '检查更新',
                    supportingText: updates.shouldNotify
                        ? '发现新版本 ${updates.latest!.versionName}'
                        : '查看是否有新版本，下载后直接安装',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (updates.shouldNotify)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Icon(
                          Icons.chevron_right,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    onTap: () => _openUpdatePage(context),
                  ),
                _SettingsTile(
                  icon: Icons.article_outlined,
                  headline: '更新日志',
                  supportingText: '查看版本改动',
                  trailing: Icon(
                    Icons.chevron_right,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const ChangelogPage(),
                    ),
                  ),
                ),
                _versionItem(theme, scheme),
              ],
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

  /// 开关 + 语义标签（原生 Switch 没有 semanticLabel 参数）。
  Widget _switch({
    required bool value,
    required String label,
    required ValueChanged<bool> onChanged,
  }) {
    return Semantics(
      label: label,
      child: Switch(value: value, onChanged: onChanged),
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
          Material(
            color: const Color(0xFF161823),
            shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
            clipBehavior: Clip.antiAlias,
            child: const SizedBox(
              width: 56,
              height: 56,
              child: Center(
                child: FaIcon(
                  FontAwesomeIcons.tiktok,
                  color: Colors.white,
                  size: 24,
                ),
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

  Widget _versionItem(ThemeData theme, ColorScheme scheme) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
        final PackageInfo? info = snapshot.data;
        return _SettingsTile(
          icon: Icons.info_outline_rounded,
          headline: '版本',
          supportingText: info == null
              ? '读取中…'
              : '${info.version} · build ${info.buildNumber}',
          trailing: Text(
            kIsWeb ? 'Web' : 'Android',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSaveLocation(
    BuildContext context,
    SettingsStore settings,
  ) async {
    final bool? choice = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ThemeData theme = Theme.of(dialogContext);
        final ColorScheme scheme = theme.colorScheme;
        return AlertDialog(
          icon: const Icon(Icons.folder_rounded),
          title: const Text('保存位置'),
          // 两个选项同级：用等权的可选行 + 单选标记，避免一主一次的按钮层级。
          contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _locationOption(
                theme: theme,
                scheme: scheme,
                icon: Icons.photo_library_rounded,
                title: '相册',
                subtitle: '保存到相册「${AppConstants.albumName}」',
                selected: settings.saveToGallery,
                onTap: () => Navigator.of(dialogContext).pop(true),
              ),
              const SizedBox(height: 8),
              _locationOption(
                theme: theme,
                scheme: scheme,
                icon: Icons.download_rounded,
                title: '系统下载目录',
                subtitle: 'Download/ClipKeep',
                selected: !settings.saveToGallery,
                onTap: () => Navigator.of(dialogContext).pop(false),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    if (choice != null) {
      await settings.setSaveToGallery(choice);
    }
  }

  Future<void> _showConcurrency(
    BuildContext context,
    SettingsStore settings,
  ) async {
    final int? choice = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ThemeData theme = Theme.of(dialogContext);
        final ColorScheme scheme = theme.colorScheme;
        return AlertDialog(
          icon: const Icon(Icons.speed_rounded),
          title: const Text('同时下载'),
          contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int n = 1; n <= 3; n++) ...<Widget>[
                _locationOption(
                  theme: theme,
                  scheme: scheme,
                  icon: Icons.downloading_rounded,
                  title: '$n 个任务',
                  subtitle: n == 1 ? '最稳，请求间隔最大' : '其余任务排队等待',
                  selected: settings.maxConcurrent == n,
                  onTap: () => Navigator.of(dialogContext).pop(n),
                ),
                if (n < 3) const SizedBox(height: 8),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    if (choice != null) {
      await settings.setMaxConcurrent(choice);
    }
  }

  /// 保存位置弹窗里的单个选项行：选中时填充 + 勾选标记。
  Widget _locationOption({
    required ThemeData theme,
    required ColorScheme scheme,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final Color foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(icon, color: foreground),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.onSecondaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...<Widget>[
                const SizedBox(width: 12),
                Icon(Icons.check_circle, size: 22, color: scheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUpdatePage(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const UpdatePage(),
      ),
    );
  }
}

class _DtkServiceCard extends StatefulWidget {
  const _DtkServiceCard();

  @override
  State<_DtkServiceCard> createState() => _DtkServiceCardState();
}

class _DtkServiceCardState extends State<_DtkServiceCard> {
  bool _testing = false;
  String? _status;
  bool _ok = false;

  Future<void> _test() async {
    final SettingsStore settings = context.read<SettingsStore>();
    if (!settings.dtkConfigured) {
      setState(() {
        _ok = false;
        _status = '请先填写 API 地址与 Key';
      });
      return;
    }
    setState(() {
      _testing = true;
      _status = '正在连接…';
      _ok = false;
    });
    final Result<String> result = await DtkClient(
      DtkConfig(baseUrl: settings.dtkBaseUrl, apiKey: settings.dtkApiKey),
    ).check();
    if (!mounted) {
      return;
    }
    setState(() {
      _testing = false;
      if (result is Ok<String>) {
        _ok = true;
        _status = result.value;
      } else if (result is Err<String>) {
        _ok = false;
        _status = result.error.message;
      }
    });
  }

  Future<void> _edit() async {
    final SettingsStore settings = context.read<SettingsStore>();
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => _DtkConfigDialog(
        initialBaseUrl: settings.dtkBaseUrl,
        initialApiKey: settings.dtkApiKey,
        onSave: (String baseUrl, String apiKey) async {
          await settings.setDtkBaseUrl(baseUrl);
          await settings.setDtkApiKey(apiKey);
        },
      ),
    );
    if (!mounted || saved != true) {
      return;
    }
    setState(() {
      _ok = true;
      _status = '已自动保存到本机';
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(const SnackBar(content: Text('解析服务凭证已保存到本机')));
  }

  Future<void> _clear() async {
    final SettingsStore settings = context.read<SettingsStore>();
    final bool confirmed = await showConfirmDialog(
      context,
      title: '清除解析服务凭证？',
      content: '清除后需要重新填写才能解析抖音链接；已保存的下载记录不受影响。',
      confirmLabel: '清除',
      icon: Icons.key_off_outlined,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await settings.setDtkBaseUrl('');
    await settings.setDtkApiKey('');
    if (!mounted) {
      return;
    }
    setState(() {
      _ok = false;
      _status = '已清除';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final SettingsStore settings = context.watch<SettingsStore>();
    final bool configured = settings.dtkConfigured;
    final bool hasAny =
        settings.dtkBaseUrl.trim().isNotEmpty ||
        settings.dtkApiKey.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            configured ? '已配置：${settings.dtkBaseUrl.trim()}' : '未配置解析服务',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: configured ? scheme.onSurface : scheme.error,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '填写自建 DTK 地址与仅含 douyin:read 权限的 API Key。'
            '凭证只保存在本机安全存储，不打包进 APK，也不会上传。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              Tooltip(
                message: configured ? '修改解析服务凭证' : '填写解析服务凭证',
                child: FilledButton.icon(
                  onPressed: _edit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const StadiumBorder(),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(configured ? '修改凭证' : '填写凭证'),
                ),
              ),
              Tooltip(
                message: '测试解析服务连接',
                child: FilledButton.tonalIcon(
                  onPressed: configured && !_testing ? _test : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: const StadiumBorder(),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
              ),
              if (hasAny)
                Tooltip(
                  message: '清除本机保存的凭证',
                  child: TextButton.icon(
                    onPressed: _clear,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: theme.textTheme.labelLarge,
                    ),
                    icon: const Icon(Icons.key_off_outlined, size: 18),
                    label: const Text('清除'),
                  ),
                ),
            ],
          ),
          if (_status != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _ok ? scheme.primary : scheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DtkConfigDialog extends StatefulWidget {
  const _DtkConfigDialog({
    required this.initialBaseUrl,
    required this.initialApiKey,
    required this.onSave,
  });

  final String initialBaseUrl;
  final String initialApiKey;
  final Future<void> Function(String baseUrl, String apiKey) onSave;

  @override
  State<_DtkConfigDialog> createState() => _DtkConfigDialogState();
}

class _DtkConfigDialogState extends State<_DtkConfigDialog> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  Timer? _saveTimer;
  bool _obscure = true;
  bool _saving = false;
  bool _dirty = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: widget.initialBaseUrl);
    _apiKey = TextEditingController(text: widget.initialApiKey);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) {
      unawaited(_persist());
    }
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _onChanged() {
    _saveTimer?.cancel();
    setState(() {
      _dirty = true;
      _saved = false;
      _error = null;
    });
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persist());
    });
  }

  String _normalizedBase() {
    String value = _baseUrl.text.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Future<bool> _persist() async {
    if (_saving) {
      return false;
    }
    final String base = _normalizedBase();
    final String key = _apiKey.text.trim();
    if (base.isEmpty && key.isEmpty) {
      _saving = true;
      await widget.onSave('', '');
      _saving = false;
      if (mounted) {
        setState(() {
          _dirty = false;
          _saved = true;
          _error = null;
        });
      }
      return true;
    }
    final Uri? uri = Uri.tryParse(base);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      if (mounted) {
        setState(() => _error = '请输入完整的 http(s) 地址');
      }
      return false;
    }
    if (key.isEmpty) {
      if (mounted) {
        setState(() => _error = 'API Key 不能为空');
      }
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.onSave(base, key);
    if (!mounted) {
      return false;
    }
    setState(() {
      _saving = false;
      _dirty = false;
      _saved = true;
    });
    return true;
  }

  Future<void> _finish() async {
    _saveTimer?.cancel();
    final bool ok = await _persist();
    if (!mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('解析服务凭证'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                onChanged: (_) => _onChanged(),
                decoration: const InputDecoration(
                  labelText: 'API 地址',
                  hintText: 'https://dtk.example.com',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => _onChanged(),
                onSubmitted: (_) => _finish(),
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: '仅需 douyin:read 权限',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '显示 API Key' : '隐藏 API Key',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '自动保存到本机安全存储；除非手动修改或清除，否则一直保留。'
                '公网地址建议使用 HTTPS。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ] else if (_saved) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '已自动保存',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        Tooltip(
          message: '关闭窗口，已输入内容会自动保存',
          child: TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ),
        Tooltip(
          message: '保存并关闭',
          child: FilledButton(
            onPressed: _saving ? null : _finish,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ),
      ],
    );
  }
}

/// 缓存占用与清理（临时分片、合成文件、更新安装包）。
class _CacheTile extends StatefulWidget {
  const _CacheTile();

  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  int? _bytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final int bytes = await context.read<DownloaderStore>().cacheBytes();
    if (mounted) {
      setState(() => _bytes = bytes);
    }
  }

  Future<void> _clear() async {
    if (_busy) {
      return;
    }
    final bool ok = await showConfirmDialog(
      context,
      title: '清理缓存',
      content: '将删除未完成的分片、合成临时文件与已下载的更新安装包，不影响已保存的成品。',
      confirmLabel: '清理',
      icon: Icons.cleaning_services_outlined,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final Result<String> result = await context
        .read<DownloaderStore>()
        .clearCache();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    if (result is Ok<String>) {
      messenger.showSnackBar(SnackBar(content: Text(result.value)));
    } else if (result is Err<String>) {
      messenger.showSnackBar(SnackBar(content: Text(result.error.message)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int? bytes = _bytes;
    return _SettingsTile(
      icon: Icons.cleaning_services_outlined,
      headline: '缓存',
      supportingText: _busy
          ? '正在清理…'
          : bytes == null
          ? '正在计算…'
          : '${formatBytes(bytes)} · 临时分片与安装包',
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      onTap: _busy ? null : _clear,
    );
  }
}

/// 设置项分组卡片：整体一张圆角卡，行之间用内缩细线分隔。
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 56,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// 单个设置行：图标 + 标题/副标题 + 尾部件，整行可点。
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.headline,
    this.supportingText,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String headline;
  final String? supportingText;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 24, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    headline,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (supportingText != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      supportingText!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
