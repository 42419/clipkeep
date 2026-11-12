import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/changelog.dart';
import '../../api/changelog_service.dart';
import '../../api/update_service.dart';
import '../../utils/result.dart';

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
  final UpdateService _service = UpdateService();
  final Dio _dio = Dio();

  bool _loading = true;
  String? _error;
  UpdateInfo? _info;
  String _currentVersion = '';
  int _currentCode = 0;
  ChangelogEntry? _notes;

  bool _downloading = false;
  double _progress = 0;
  int _received = 0;
  int _total = 0;
  DateTime? _lastCheckedAt;

  /// 是否存在比本机更新的版本（先比 versionName，再比 versionCode）。
  bool get _hasUpdate =>
      _info != null && _info!.isNewerThan(_currentVersion, _currentCode);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PackageInfo pkg = await PackageInfo.fromPlatform();
      _currentVersion = pkg.version;
      _currentCode = int.tryParse(pkg.buildNumber) ?? 0;
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法读取当前版本，请重试';
          _lastCheckedAt = DateTime.now();
        });
      }
      return;
    }
    final Result<UpdateInfo> result = await _service.check();
    if (!mounted) {
      return;
    }
    if (result is Err<UpdateInfo>) {
      setState(() {
        _loading = false;
        _error = result.error.message;
        _lastCheckedAt = DateTime.now();
      });
      return;
    }
    final UpdateInfo info = (result as Ok<UpdateInfo>).value;
    setState(() {
      _info = info;
      _loading = false;
      _lastCheckedAt = DateTime.now();
    });
    if (info.isNewerThan(_currentVersion, _currentCode) && _notes == null) {
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

  /// 当前设备的 ABI 优先级（与 build.gradle 的 abiFilters 对齐）。
  List<String> _abiNames() {
    final Abi abi = Abi.current();
    if (abi == Abi.androidArm64) {
      return <String>['arm64-v8a'];
    }
    if (abi == Abi.androidArm) {
      return <String>['armeabi-v7a', 'arm64-v8a'];
    }
    if (abi == Abi.androidX64) {
      return <String>['x86_64'];
    }
    return <String>['arm64-v8a'];
  }

  Future<void> _downloadAndInstall() async {
    final UpdateInfo? info = _info;
    if (info == null || _downloading) {
      return;
    }
    final UpdateApk? apk = info.apkFor(_abiNames());
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
              _buildStatusCard(theme, scheme),
              if (_hasUpdate) ...<Widget>[
                if (_notes != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildNotes(theme, scheme, _notes!),
                ],
                const SizedBox(height: 16),
                _buildDownloadCard(theme, scheme, _info!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme, ColorScheme scheme) {
    final bool hasUpdate = _hasUpdate;
    final String subtitle = _loading
        ? '正在检查…'
        : _error ?? (hasUpdate ? '有新版本可以安装' : '当前已是最新');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                hasUpdate ? Icons.system_update_alt : Icons.verified_outlined,
                size: 28,
                color: hasUpdate ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      hasUpdate ? '发现新版本 ${_info!.versionName}' : '已是最新版本',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _error == null
                            ? scheme.onSurfaceVariant
                            : scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow(
            theme,
            scheme,
            '当前版本',
            _versionText(_currentVersion, _currentCode),
          ),
          if (_info != null)
            _infoRow(
              theme,
              scheme,
              '最新版本',
              _versionText(_info!.versionName, _info!.versionCode),
            ),
          if (_info != null && _info!.publishedAt.isNotEmpty)
            _infoRow(theme, scheme, '发布日期', _info!.publishedAt),
          if (_lastCheckedAt != null)
            _infoRow(theme, scheme, '上次检查', _timeText(_lastCheckedAt!)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message: '重新检查更新',
              child: TextButton.icon(
                onPressed: _loading ? null : _load,
                style: TextButton.styleFrom(
                  minimumSize: const Size(64, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新检查'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _versionText(String name, int code) =>
      code > 0 ? '$name ($code)' : name;

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
    final UpdateApk? apk = info.apkFor(_abiNames());
    final String sizeText = apk == null || apk.size <= 0
        ? ''
        : '${(apk.size / 1024 / 1024).toStringAsFixed(1)} MB';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
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
              _abiNames().first,
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

  Widget _buildNotes(
    ThemeData theme,
    ColorScheme scheme,
    ChangelogEntry entry,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
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
