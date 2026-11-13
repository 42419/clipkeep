import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../api/changelog.dart';
import '../../api/changelog_service.dart';
import '../../api/update_service.dart';
import '../../platform/abi_names.dart';
import '../../stores/update_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/result.dart';
import 'changelog_page.dart';

/// 检查更新：展示版本差异与更新说明，下载并调起系统安装。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  static const MethodChannel _installer = MethodChannel(
    'clipkeep/apk_installer',
  );
  final Dio _dio = Dio();

  ChangelogEntry? _notes;

  bool _downloading = false;
  double _progress = 0;
  int _received = 0;
  int _total = 0;

  /// 检查更新的状态由 Store 持有，页面只负责展示。
  UpdateStore get _store => context.read<UpdateStore>();
  UpdateInfo? get _info => _store.latest;
  bool get _loading => _store.checking;
  String? get _error => _store.error;
  String get _currentVersion => _store.currentVersion;
  DateTime? get _lastCheckedAt => _store.lastCheckedAt;
  bool get _hasUpdate => _store.hasUpdate;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final UpdateStore store = _store;
    await store.check();
    if (!mounted) {
      return;
    }
    final UpdateInfo? info = store.latest;
    if (store.hasUpdate && info != null && _notes == null) {
      unawaited(_loadNotes(info.versionName));
    }
  }

  /// 从内置 CHANGELOG 取出该版本的说明；失败只影响说明区，不影响下载。
  Future<void> _loadNotes(String versionName) async {
    final Result<Changelog> result = await ChangelogService().fetch();
    if (!mounted || result is! Ok<Changelog>) {
      return;
    }
    final ChangelogEntry? entry = result.value.entryFor(versionName);
    if (entry != null) {
      setState(() => _notes = entry);
    }
  }

  Future<void> _downloadAndInstall() async {
    final UpdateInfo? info = _info;
    if (info == null || _downloading) {
      return;
    }
    final UpdateApk? apk = info.apkFor(abiNames());
    final List<String> urls = apk?.downloadUrls ?? const <String>[];
    if (apk == null || urls.isEmpty) {
      _showSnack('这个版本没有适配当前设备的安装包');
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
      _received = 0;
      _total = apk.size;
    });

    File? file;
    try {
      final Directory dir = await getTemporaryDirectory();
      // 与 res/xml/file_paths.xml 的 <cache-path path="updates/"> 保持一致。
      final Directory updates = Directory('${dir.path}/updates');
      if (!await updates.exists()) {
        await updates.create(recursive: true);
      }
      file = File('${updates.path}/${apk.asset}');
      Object? lastError;
      for (int i = 0; i < urls.length; i++) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
          await _dio.download(
            urls[i],
            file.path,
            onReceiveProgress: (int received, int total) {
              if (!mounted) {
                return;
              }
              setState(() {
                _received = received;
                _total = total > 0 ? total : apk.size;
                _progress = _total > 0 ? received / _total : 0;
              });
            },
          );
          final String digest = sha256
              .convert(await file.readAsBytes())
              .toString();
          if (apk.sha256.isNotEmpty && digest != apk.sha256) {
            await file.delete();
            throw const UpdateException('安装包校验失败');
          }
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (await file.exists()) {
            await file.delete();
          }
          if (i == urls.length - 1) {
            rethrow;
          }
          if (mounted) {
            setState(() {
              _progress = 0;
              _received = 0;
            });
            _showSnack('当前下载源失败，正在尝试备用源…');
          }
        }
      }
      if (lastError != null) {
        throw lastError;
      }
      if (!mounted) {
        return;
      }
      setState(() => _downloading = false);
      await _install(file.path);
    } on UpdateException catch (e) {
      _failDownload(e.message);
    } on DioException catch (e) {
      _failDownload('下载失败：${e.message ?? e.type.name}');
    } catch (e) {
      _failDownload('下载失败：$e');
    }
  }

  void _failDownload(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _downloading = false;
      _progress = 0;
    });
    _showSnack(message);
  }

  Future<void> _install(String path) async {
    try {
      await _installer.invokeMethod<void>('install', <String, String>{
        'path': path,
      });
    } on PlatformException catch (e) {
      _showSnack('无法调起安装：${e.message ?? '未知错误'}');
    } on MissingPluginException {
      _showSnack('当前版本不支持应用内安装');
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 订阅 Store：检查中/结果/忽略状态变化时重建页面。
    context.watch<UpdateStore>();
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        title: const Text('检查更新'),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            // 内容不足一屏时也能下拉刷新。
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: <Widget>[
              _buildHero(theme, scheme),
              const SizedBox(height: 16),
              _buildVersionGrid(theme, scheme),
              if (_hasUpdate) ...<Widget>[
                if (_notes != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildNotes(theme, scheme, _notes!),
                ],
                const SizedBox(height: 16),
                _buildDownloadCard(theme, scheme, _info!),
                const SizedBox(height: 4),
                _buildIgnoreRow(theme, scheme),
              ],
              const SizedBox(height: 16),
              _buildAbout(theme, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(ThemeData theme, ColorScheme scheme) {
    final bool hasUpdate = _hasUpdate;
    final bool failed = _error != null;
    final Color background = failed
        ? scheme.errorContainer
        : hasUpdate
        ? scheme.primaryContainer
        : scheme.surfaceContainerLow;
    final Color foreground = failed
        ? scheme.onErrorContainer
        : hasUpdate
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final Color iconBackground = failed
        ? scheme.error
        : hasUpdate
        ? scheme.primary
        : scheme.surfaceContainerHighest;
    final Color iconForeground = failed
        ? scheme.onError
        : hasUpdate
        ? scheme.onPrimary
        : scheme.onSurfaceVariant;
    final String title = _loading
        ? '正在检查更新'
        : failed
        ? '检查失败'
        : hasUpdate
        ? '发现新版本 ${_info!.versionName}'
        : '已是最新版本';
    final String subtitle = _loading
        ? '正在获取最新版本信息'
        : failed
        ? (_error ?? '请稍后重试')
        : hasUpdate
        ? '新版本已发布，安装后即可使用'
        : '当前版本已是最新，无需更新';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Material(
                color: iconBackground,
                shape: MaterialShapeBorder(shape: MaterialShapes.cookie12Sided),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Center(
                    child: Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : hasUpdate
                          ? Icons.system_update_alt_rounded
                          : Icons.verified_rounded,
                      color: iconForeground,
                      size: 26,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 2),
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground.withValues(alpha: 0.75),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: foreground,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                _lastCheckedAt == null
                    ? '尚未检查'
                    : '上次检查 ${_timeText(_lastCheckedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foreground.withValues(alpha: 0.7),
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const Spacer(),
              Tooltip(
                message: '重新检查更新',
                child: TextButton.icon(
                  onPressed: _loading ? null : _load,
                  style: TextButton.styleFrom(
                    foregroundColor: foreground,
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重新检查'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVersionGrid(ThemeData theme, ColorScheme scheme) {
    final String latest = _info?.versionName ?? '—';
    final String published = _info == null || _info!.publishedAt.isEmpty
        ? '—'
        : _info!.publishedAt;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _versionCell(
                  theme,
                  scheme,
                  icon: Icons.smartphone_rounded,
                  label: '当前版本',
                  version: _currentVersion.isEmpty ? '—' : _currentVersion,
                ),
              ),
              Expanded(
                child: _versionCell(
                  theme,
                  scheme,
                  icon: Icons.cloud_outlined,
                  label: '最新版本',
                  version: latest,
                ),
              ),
            ],
          ),
          Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: scheme.outlineVariant,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _metaCell(theme, scheme, '发布日期', published)),
              Expanded(
                child: _metaCell(
                  theme,
                  scheme,
                  '上次检查',
                  _lastCheckedAt == null ? '—' : _timeText(_lastCheckedAt!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _versionCell(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String version,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            version,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaCell(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbout(ThemeData theme, ColorScheme scheme) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _aboutRow(
            theme,
            scheme,
            Icons.cloud_download_outlined,
            '更新源',
            'CNB 主源 · GitHub 备用',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant,
            ),
          ),
          _aboutRow(
            theme,
            scheme,
            Icons.shield_outlined,
            '安装包校验',
            'SHA-256 校验后经系统安装器安装',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: '查看完整更新日志',
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const ChangelogPage(),
                    ),
                  );
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size(64, 52),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                icon: const Icon(Icons.history_rounded, size: 18),
                label: const Text('查看完整更新日志'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(
    ThemeData theme,
    ColorScheme scheme,
    IconData icon,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _timeText(DateTime time) {
    final String hh = time.hour.toString().padLeft(2, '0');
    final String mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Widget _buildDownloadCard(
    ThemeData theme,
    ColorScheme scheme,
    UpdateInfo info,
  ) {
    final UpdateApk? apk = info.apkFor(abiNames());
    final String sizeText = apk == null || apk.size <= 0
        ? ''
        : '${(apk.size / 1024 / 1024).toStringAsFixed(1)} MB';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '下载安装包',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            <String>[
              if (sizeText.isNotEmpty) sizeText,
              // web 上 abiNames() 恒为空，给个兜底文案。
              abiNames().isEmpty ? '未知架构' : abiNames().first,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 14),
          if (_downloading) ...<Widget>[
            LinearProgressIndicator(
              value: _progress,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHigh,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 8),
            Text(
              '${(_progress * 100).toStringAsFixed(1)}% · '
              '${_mb(_received)} / ${_mb(_total)} MB',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: Tooltip(
                message: '下载并安装 ${info.versionName}',
                child: FilledButton.icon(
                  onPressed: _downloadAndInstall,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    shape: const StadiumBorder(),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                  icon: const Icon(Icons.download),
                  label: Text(sizeText.isEmpty ? '下载并安装' : '下载并安装 · $sizeText'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 忽略/恢复当前版本：避免反复提醒，用户主动进页面仍能看到更新。
  Widget _buildIgnoreRow(ThemeData theme, ColorScheme scheme) {
    final UpdateStore store = _store;
    final String? version = store.latestVersionName;
    final bool ignored = version != null && store.ignoredVersion == version;
    return Align(
      alignment: Alignment.centerRight,
      child: Tooltip(
        message: ignored ? '恢复该版本的更新提醒' : '不再提示这个版本',
        child: TextButton(
          onPressed: () {
            if (ignored) {
              unawaited(store.clearIgnored());
            } else {
              unawaited(store.ignoreCurrent());
            }
          },
          style: TextButton.styleFrom(
            minimumSize: const Size(64, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: scheme.onSurfaceVariant,
          ),
          child: Text(ignored ? '已忽略 $version · 恢复提醒' : '忽略此版本'),
        ),
      ),
    );
  }

  Widget _buildNotes(
    ThemeData theme,
    ColorScheme scheme,
    ChangelogEntry entry,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '更新内容 · ${entry.versionName}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          for (final ChangelogSection section in entry.sections) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              section.title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            for (final String item in section.items)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '· $item',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
}
