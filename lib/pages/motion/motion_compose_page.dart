import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../stores/downloader_store.dart';
import '../../theme/app_theme.dart';
import '../../utils/file_picker_channel.dart';
import '../../utils/format.dart';
import '../../utils/result.dart';

/// 手动把本地图片 + 视频合成为 Motion Photo（实况照片）。
class MotionComposePage extends StatefulWidget {
  const MotionComposePage({super.key});

  @override
  State<MotionComposePage> createState() => _MotionComposePageState();
}

class _MotionComposePageState extends State<MotionComposePage> {
  String? _imagePath;
  String? _videoPath;
  bool _busy = false;
  String? _phase;

  bool get _ready => _imagePath != null && _videoPath != null;

  Future<void> _pick({required bool image}) async {
    if (_busy) {
      return;
    }
    try {
      final String? path = image
          ? await FilePickerChannel.pickImage()
          : await FilePickerChannel.pickVideo();
      if (!mounted || path == null) {
        return;
      }
      setState(() {
        if (image) {
          _imagePath = path;
        } else {
          _videoPath = path;
        }
      });
    } on FilePickException catch (e) {
      _show(e.message);
    } catch (e) {
      _show('选择文件失败：$e');
    }
  }

  Future<void> _run({required bool compose}) async {
    final String? image = _imagePath;
    final String? video = _videoPath;
    if (image == null || video == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _phase = compose ? '正在合成动态照片…' : '正在保存…';
    });
    final DownloaderStore store = context.read<DownloaderStore>();
    Result<String> result;
    try {
      result = compose
          ? await store.composeMotionPhoto(imagePath: image, videoPath: video)
          : await store.saveLocalPair(imagePath: image, videoPath: video);
    } catch (e) {
      result = Err<String>(AppError('处理失败：$e', cause: e));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _phase = null;
    });
    if (result is Ok<String>) {
      _show(result.value);
    } else if (result is Err<String>) {
      _show(result.error.message);
    }
  }

  void _show(String message) {
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
        title: const Text('实况图合成'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.auto_awesome_motion_outlined,
                  color: scheme.primary,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '选择一张图片和一段视频，合成为可播放的动态照片（Motion Photo）。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _PickCard(
            title: '图片',
            hint: 'JPG / PNG / WebP',
            path: _imagePath,
            enabled: !_busy,
            thumbnail: true,
            onPick: () => _pick(image: true),
          ),
          const SizedBox(height: 12),
          _PickCard(
            title: '视频',
            hint: 'MP4',
            path: _videoPath,
            enabled: !_busy,
            thumbnail: false,
            onPick: () => _pick(image: false),
          ),
          const SizedBox(height: 20),
          if (_busy) ...<Widget>[
            LinearProgressIndicator(
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHigh,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 8),
            Text(
              _phase ?? '处理中…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Tooltip(
            message: '合成并保存为动态照片',
            child: FilledButton.icon(
              onPressed: _ready && !_busy ? () => _run(compose: true) : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 56),
                textStyle: theme.textTheme.titleMedium,
              ),
              icon: const Icon(Icons.auto_awesome_motion_outlined),
              label: const Text('合成并保存'),
            ),
          ),
          const SizedBox(height: 10),
          Tooltip(
            message: '不做合成，图片和视频分别保存',
            child: OutlinedButton.icon(
              onPressed: _ready && !_busy ? () => _run(compose: false) : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(64, 56),
                textStyle: theme.textTheme.titleMedium,
              ),
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('图片和视频分别保存'),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '动态照片依赖相册支持：部分机型或旧系统只会显示静态图，'
            '此时请用「图片和视频分别保存」，或把合成后的文件分享到支持的应用查看。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PickCard extends StatelessWidget {
  const _PickCard({
    required this.title,
    required this.hint,
    required this.path,
    required this.enabled,
    required this.thumbnail,
    required this.onPick,
  });

  final String title;
  final String hint;
  final String? path;
  final bool enabled;
  final bool thumbnail;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? file = path;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: file != null && thumbnail
                  ? Image.file(
                      File(file),
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                      errorBuilder: (
                        BuildContext context,
                        Object error,
                        StackTrace? stack,
                      ) => _placeholder(scheme),
                    )
                  : _placeholder(scheme),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  file == null ? '未选择（$hint）' : _describe(file),
                  maxLines: 2,
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
          const SizedBox(width: 8),
          Tooltip(
            message: '选择$title',
            child: FilledButton.tonal(
              onPressed: enabled ? onPick : null,
              child: const Text('选择'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        thumbnail ? Icons.image_outlined : Icons.movie_outlined,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  String _describe(String file) {
    final String name = file.split(Platform.pathSeparator).last;
    try {
      final int size = File(file).lengthSync();
      return size > 0 ? '$name · ${formatBytes(size)}' : name;
    } catch (_) {
      return name;
    }
  }
}
