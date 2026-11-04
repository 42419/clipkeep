import '../../../../core/result.dart';
import '../../../../ffi/bdl_service.dart';
import '../../domain/entities/parsed_source.dart';

/// 调用 Rust 侧 bdl_parse 并把 JSON 映射为领域模型。
class BdlDataSource {
  BdlDataSource(this._service, this._stateDirProvider);

  final BdlService _service;
  final Future<String> Function() _stateDirProvider;

  Future<Result<ParsedSource>> parse(String input) async {
    final stateDir = await _stateDirProvider();
    final response = await _service.parse(
      input: input,
      stateDir: stateDir,
      withStreams: true,
    );
    if (!response.ok) {
      return Err(AppError(response.error ?? '解析失败'));
    }
    final data = response.data;
    if (data == null) {
      return const Err(AppError('解析结果为空'));
    }
    try {
      return Ok(_mapTree(data));
    } catch (e) {
      return Err(AppError('解析结果格式异常', cause: e));
    }
  }

  ParsedSource _mapTree(Map<String, dynamic> tree) {
    final source =
        (tree['source'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final groups = (tree['groups'] as List?) ?? const <dynamic>[];
    final items = <Map<String, dynamic>>[];
    for (final group in groups) {
      final groupMap = (group as Map).cast<String, dynamic>();
      final list = (groupMap['items'] as List?) ?? const <dynamic>[];
      for (final item in list) {
        items.add((item as Map).cast<String, dynamic>());
      }
    }
    final first = items.isNotEmpty ? items.first : <String, dynamic>{};
    final parts = <MediaPart>[];
    final rawParts = (first['parts'] as List?) ?? const <dynamic>[];
    for (final part in rawParts) {
      parts.add(_mapPart((part as Map).cast<String, dynamic>()));
    }
    return ParsedSource(
      title: (first['title'] as String?) ??
          (source['title'] as String?) ??
          '未知标题',
      author: (first['owner_name'] as String?) ?? '',
      coverUrl: first['cover_url'] as String?,
      parts: parts,
    );
  }

  MediaPart _mapPart(Map<String, dynamic> part) {
    final streams = <MediaStream>[];
    final rawStreams = (part['streams'] as List?) ?? const <dynamic>[];
    for (final stream in rawStreams) {
      final streamMap = (stream as Map).cast<String, dynamic>();
      final quality = (streamMap['quality'] as Map?)?.cast<String, dynamic>();
      final headers = <String, String>{};
      final rawHeaders = (streamMap['headers'] as List?) ?? const <dynamic>[];
      for (final header in rawHeaders) {
        final headerMap = (header as Map).cast<String, dynamic>();
        final name = headerMap['name'] as String?;
        final value = headerMap['value'] as String?;
        if (name != null && value != null) {
          headers[name] = value;
        }
      }
      final urls = ((streamMap['urls'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
      streams.add(MediaStream(
        kind: (streamMap['kind'] as String?) ?? '',
        quality: (quality?['value'] as num?)?.toInt() ?? 0,
        codec: (streamMap['codec'] as String?) ?? '',
        urls: urls,
        headers: headers,
      ));
    }
    return MediaPart(
      id: (part['id'] as String?) ?? '',
      title: (part['title'] as String?) ?? '',
      durationSeconds: (part['duration_seconds'] as num?)?.toInt(),
      streams: streams,
    );
  }
}
