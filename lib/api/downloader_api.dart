import 'package:path_provider/path_provider.dart';

import '../utils/bdl_service.dart';
import '../utils/media_downloader.dart';
import '../utils/result.dart';
import '../viewmodels/parsed_source.dart';

/// 数据接口层：封装 B 站解析与媒体下载，供 Store 调用。
class DownloaderApi {
  DownloaderApi({BdlService? bdlService, MediaDownloader? mediaDownloader})
      : _bdl = bdlService ?? const BdlService(),
        _media = mediaDownloader ?? MediaDownloader();

  final BdlService _bdl;
  final MediaDownloader _media;

  Future<Result<ParsedSource>> parse(String input) async {
    final dir = await getApplicationSupportDirectory();
    final response = await _bdl.parse(
      input: input,
      stateDir: dir.path,
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
      return Ok(_toParsedSource(data));
    } catch (e) {
      return Err(AppError('解析结果格式异常', cause: e));
    }
  }

  Future<Result<String>> download(
    MediaPart part, {
    void Function(double progress)? onProgress,
  }) {
    return _media.download(part, onProgress: onProgress);
  }

  ParsedSource _toParsedSource(Map<String, dynamic> tree) {
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
      parts.add(_toPart((part as Map).cast<String, dynamic>()));
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

  MediaPart _toPart(Map<String, dynamic> part) {
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
