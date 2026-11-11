/// 格式化工具。
String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 MB';
  }
  final double mb = bytes / (1024 * 1024);
  if (mb >= 1024) {
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
  return '${mb.toStringAsFixed(1)} MB';
}

String formatSpeed(double bytesPerSec) {
  if (bytesPerSec <= 0) {
    return '--';
  }
  final double mbps = bytesPerSec / (1024 * 1024);
  if (mbps >= 1) {
    return '${mbps.toStringAsFixed(1)} MB/s';
  }
  final double kbps = bytesPerSec / 1024;
  return '${kbps.toStringAsFixed(0)} KB/s';
}

String formatEta(int seconds) {
  if (seconds <= 0) {
    return '--';
  }
  if (seconds < 60) {
    return '$seconds 秒';
  }
  final int m = seconds ~/ 60;
  final int s = seconds % 60;
  return '$m 分 $s 秒';
}

/// 点赞/播放等计数：1.2w / 3.4亿。
String formatCount(int? value) {
  final int n = value ?? 0;
  if (n <= 0) {
    return '0';
  }
  if (n >= 100000000) {
    return '${(n / 100000000).toStringAsFixed(1)}亿';
  }
  if (n >= 10000) {
    return '${(n / 10000).toStringAsFixed(1)}w';
  }
  return '$n';
}
