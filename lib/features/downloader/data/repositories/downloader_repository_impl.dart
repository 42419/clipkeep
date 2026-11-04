import '../../../../core/result.dart';
import '../../domain/entities/parsed_source.dart';
import '../../domain/repositories/downloader_repository.dart';
import '../datasources/bdl_datasource.dart';
import '../datasources/media_downloader.dart';

class DownloaderRepositoryImpl implements DownloaderRepository {
  DownloaderRepositoryImpl(this._bdl, this._media);

  final BdlDataSource _bdl;
  final MediaDownloader _media;

  @override
  Future<Result<ParsedSource>> parse(String input) => _bdl.parse(input);

  @override
  Future<Result<String>> download(
    MediaPart part, {
    void Function(double progress)? onProgress,
  }) =>
      _media.download(part, onProgress: onProgress);
}
