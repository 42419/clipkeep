import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
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
      // MD3 Expressive；dynamicColoring 让配色跟随系统壁纸（Material You）。
      child: M3EMaterialApp(
        title: 'ClipKeep',
        debugShowCheckedModeBanner: false,
        dynamicColoring: true,
        autoTheming: true,
        data: M3EThemeData.light(seedColor: Colors.deepPurple),
        home: const DownloaderPage(),
      ),
    );
  }
}
