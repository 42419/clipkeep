import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/downloader_controller.dart';
import '../../domain/entities/parsed_source.dart';

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DownloaderController>();
    return Scaffold(
      appBar: AppBar(title: const Text('ClipKeep · B站下载')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _input,
            decoration: const InputDecoration(
              labelText: 'B站链接或 BV 号',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => controller.parse(value),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                controller.parsing ? null : () => controller.parse(_input.text),
            icon: const Icon(Icons.search),
            label: Text(controller.parsing ? '解析中…' : '解析'),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                controller.error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          if (controller.source != null) ..._buildResult(context, controller),
        ],
      ),
    );
  }

  List<Widget> _buildResult(
    BuildContext context,
    DownloaderController controller,
  ) {
    final source = controller.source!;
    final widgets = <Widget>[
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (source.coverUrl != null && source.coverUrl!.isNotEmpty)
                Image.network(source.coverUrl!, height: 160, fit: BoxFit.cover),
              const SizedBox(height: 8),
              Text(
                source.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(source.author),
            ],
          ),
        ),
      ),
    ];
    for (final part in source.parts) {
      final video = part.pickVideo();
      final label = video == null
          ? '无可用视频流'
          : '${qualityLabel(video.quality)} · ${video.codec}';
      widgets.add(
        Card(
          child: ListTile(
            title: Text(
              part.title.isEmpty ? '视频' : part.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(label),
            trailing: controller.downloading
                ? null
                : IconButton(
                    icon: const Icon(Icons.download),
                    onPressed: () => controller.download(part),
                  ),
          ),
        ),
      );
    }
    if (controller.downloading) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            children: [
              LinearProgressIndicator(value: controller.progress),
              const SizedBox(height: 6),
              Text(
                '下载中 ${(controller.progress * 100).toStringAsFixed(0)}%',
              ),
            ],
          ),
        ),
      );
    }
    if (controller.savedMessage != null) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            controller.savedMessage!,
            style: const TextStyle(color: Colors.green),
          ),
        ),
      );
    }
    return widgets;
  }
}
