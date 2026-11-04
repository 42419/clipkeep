import '../../../../core/result.dart';
import '../entities/parsed_source.dart';

/// 下载器领域仓库接口。
abstract class DownloaderRepository {
  Future<Result<ParsedSource>> parse(String input);

  Future<Result<String>> download(
    MediaPart part, {
    void Function(double progress)? onProgress,
  });
}
