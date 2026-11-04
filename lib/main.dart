import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'features/downloader/data/datasources/bdl_datasource.dart';
import 'features/downloader/data/datasources/media_downloader.dart';
import 'features/downloader/data/repositories/downloader_repository_impl.dart';
import 'features/downloader/presentation/controllers/downloader_controller.dart';
import 'features/downloader/presentation/pages/downloader_page.dart';
import 'ffi/bdl_service.dart';

void main() {
  runApp(const ClipKeepApp());
}

class ClipKeepApp extends StatelessWidget {
  const ClipKeepApp({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = DownloaderRepositoryImpl(
      BdlDataSource(const BdlService(), () async {
        final dir = await getApplicationSupportDirectory();
        return dir.path;
      }),
      MediaDownloader(),
    );
    return ChangeNotifierProvider<DownloaderController>(
      create: (_) => DownloaderController(repository),
      child: MaterialApp(
        title: 'ClipKeep',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const DownloaderPage(),
      ),
    );
  }
}
