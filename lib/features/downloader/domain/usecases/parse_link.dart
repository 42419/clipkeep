import '../../../../core/result.dart';
import '../entities/parsed_source.dart';
import '../repositories/downloader_repository.dart';

/// 解析一个 B 站链接/BV 号。
class ParseLink {
  const ParseLink(this._repository);

  final DownloaderRepository _repository;

  Future<Result<ParsedSource>> call(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return Future.value(const Err(AppError('请输入视频链接或 BV 号')));
    }
    return _repository.parse(trimmed);
  }
}
