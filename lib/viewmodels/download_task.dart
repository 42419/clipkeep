import 'parsed_source.dart';

/// 下载任务状态。
enum DownloadStatus { downloading, paused, completed, failed }

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

  /// 非空表示当前处于特殊阶段（如「正在合并音视频…」）。
  final String? phase;
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
    this.status = DownloadStatus.downloading,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0,
    this.error,
    this.savedMessage,
    this.thumbnailPath,
    this.phase,
  });

  final String id;
  final String title;
  final String platform;
  final String qualityLabel;
  final MediaPart? part;
  final int? videoQuality;
  final bool audioOnly;
  final bool coverOnly;
  final bool saveCover;
  final String? coverUrl;
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

  bool get isActive =>
      status == DownloadStatus.downloading || status == DownloadStatus.paused;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isCompleted => status == DownloadStatus.completed;

  /// 仅持久化展示字段（已完成历史）。
  Map<String, dynamic> toRecord() => <String, dynamic>{
        'id': id,
        'title': title,
        'platform': platform,
        'qualityLabel': qualityLabel,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'coverUrl': coverUrl,
        'thumbnailPath': thumbnailPath,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DownloadTask.fromRecord(Map<String, dynamic> json) => DownloadTask(
        id: (json['id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        platform: (json['platform'] as String?) ?? '',
        qualityLabel: (json['qualityLabel'] as String?) ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
                DateTime.now(),
        status: DownloadStatus.completed,
        progress: 1,
        receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        coverUrl: json['coverUrl'] as String?,
        thumbnailPath: json['thumbnailPath'] as String?,
      );
}
