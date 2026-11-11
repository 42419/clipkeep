import 'parsed_source.dart';

/// 下载任务状态。
enum DownloadStatus { queued, downloading, paused, completed, failed }

/// 下载进度快照（真实字节数/速度）。
class DownloadProgress {
  const DownloadProgress({
    required this.fraction,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.phase,
  });

  final double fraction;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytesPerSec;

  /// 非空表示当前处于特殊阶段（如「排队中…」「网络异常，X 秒后重试」）。
  final String? phase;
}

/// 已保存到相册/下载目录的一个文件，用于「打开/分享」。
class SavedMediaFile {
  const SavedMediaFile({required this.name, required this.mime});

  /// MediaStore 里的 DISPLAY_NAME（相册保存也沿用源文件名）。
  final String name;
  final String mime;
}

/// 一条下载任务（进行中/暂停/失败/已完成）。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.platform,
    required this.qualityLabel,
    required this.createdAt,
    this.part,
    this.videoQuality,
    this.audioOnly = false,
    this.coverOnly = false,
    this.saveCover = false,
    this.coverUrl,
    this.sourceUrl,
    this.status = DownloadStatus.downloading,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.error,
    this.savedMessage,
    this.thumbnailPath,
    this.phase,
    this.fileStem,
    this.savedNames = const <String>[],
  });

  final String id;
  final String title;
  final String platform;
  final String qualityLabel;
  MediaPart? part;
  final int? videoQuality;
  final bool audioOnly;
  final bool coverOnly;
  final bool saveCover;
  final String? coverUrl;

  /// 原始解析链接（抖音为 web_url），用于重启后重新解析。
  final String? sourceUrl;
  final DateTime createdAt;

  DownloadStatus status;
  double progress;
  int receivedBytes;
  int totalBytes;
  double speedBytesPerSec;
  String? error;
  String? savedMessage;
  String? thumbnailPath;
  String? phase;

  /// 可读文件名主 stem（不含扩展名）；旧记录为空时回退时间戳命名。
  final String? fileStem;

  /// 已保存文件的 DISPLAY_NAME 列表，用于打开/分享。
  List<String> savedNames;

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.paused;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isCompleted => status == DownloadStatus.completed;

  /// 持久化展示与恢复字段：已完成记录可回看，未完成任务重启后可继续/删除。
  Map<String, dynamic> toRecord() => <String, dynamic>{
    'id': id,
    'title': title,
    'platform': platform,
    'qualityLabel': qualityLabel,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'coverUrl': coverUrl,
    'sourceUrl': sourceUrl,
    'thumbnailPath': thumbnailPath,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'progress': progress,
    'videoQuality': videoQuality,
    'audioOnly': audioOnly,
    'coverOnly': coverOnly,
    'saveCover': saveCover,
    'error': error,
    'phase': phase,
    'savedMessage': savedMessage,
    'fileStem': fileStem,
    'savedNames': savedNames,
    'partId': part?.id,
    'partTitle': part?.title,
    'partDuration': part?.durationSeconds,
  };

  factory DownloadTask.fromRecord(Map<String, dynamic> json) {
    final DownloadStatus saved = _statusFrom(json['status'] as String?);
    // 进程被杀时可能残留 downloading/queued：恢复为暂停，避免 UI 显示一个永远在下载的任务。
    final DownloadStatus status =
        saved == DownloadStatus.downloading || saved == DownloadStatus.queued
        ? DownloadStatus.paused
        : saved;
    final String id = (json['id'] as String?) ?? '';
    final String title = (json['title'] as String?) ?? '';
    final String? partId = json['partId'] as String?;
    return DownloadTask(
      id: id,
      title: title,
      platform: _resolvePlatform(json),
      qualityLabel: (json['qualityLabel'] as String?) ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      status: status,
      progress: status == DownloadStatus.completed
          ? 1
          : ((json['progress'] as num?)?.toDouble() ?? 0),
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      coverUrl: json['coverUrl'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      videoQuality: (json['videoQuality'] as num?)?.toInt(),
      audioOnly: json['audioOnly'] == true,
      coverOnly: json['coverOnly'] == true,
      saveCover: json['saveCover'] == true,
      error: json['error'] as String?,
      phase: json['phase'] as String?,
      savedMessage: json['savedMessage'] as String?,
      fileStem: json['fileStem'] as String?,
      savedNames:
          (json['savedNames'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      part: partId == null || partId.isEmpty
          ? null
          : MediaPart(
              id: partId,
              title: (json['partTitle'] as String?) ?? title,
              durationSeconds: (json['partDuration'] as num?)?.toInt(),
              // 签名 URL 不持久化；恢复后由 resume/retry 重新拉流。
              streams: const <MediaStream>[],
            ),
    );
  }
}

DownloadStatus _statusFrom(String? raw) {
  if (raw == null || raw.isEmpty) {
    return DownloadStatus.completed;
  }
  return DownloadStatus.values.firstWhere(
    (DownloadStatus value) => value.name == raw,
    orElse: () => DownloadStatus.completed,
  );
}

/// 旧记录没有 platform 时，按链接推断，避免显示空平台。
String _resolvePlatform(Map<String, dynamic> json) {
  final String value = (json['platform'] as String?) ?? '';
  if (value.isNotEmpty) {
    return value;
  }
  final String probe = '${json['sourceUrl'] ?? ''} ${json['coverUrl'] ?? ''}'
      .toLowerCase();
  if (probe.contains('douyin')) {
    return '抖音';
  }
  return '未知';
}
