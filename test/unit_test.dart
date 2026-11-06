import 'package:clipkeep/api/dtk_mapper.dart';
import 'package:clipkeep/stores/auth_store.dart';
import 'package:clipkeep/utils/format.dart';
import 'package:clipkeep/viewmodels/download_task.dart';
import 'package:clipkeep/viewmodels/parsed_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('qualityLabel', () {
    test('B 站档位映射', () {
      expect(qualityLabel(16), '360P');
      expect(qualityLabel(80), '1080P');
      expect(qualityLabel(120), '4K');
    });

    test('抖音按像素高兜底', () {
      expect(qualityLabel(720), '720P');
      expect(qualityLabel(1080), '1080P');
    });

    test('未知低值保持 QN 前缀', () {
      expect(qualityLabel(1), 'QN1');
    });
  });

  group('格式化', () {
    test('文件大小', () {
      expect(formatBytes(0), '0 MB');
      expect(formatBytes(1536 * 1024), '1.5 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });

    test('速度', () {
      expect(formatSpeed(0), '--');
      expect(formatSpeed(512 * 1024), '512 KB/s');
      expect(formatSpeed(2 * 1024 * 1024), '2.0 MB/s');
    });

    test('剩余时间', () {
      expect(formatEta(0), '--');
      expect(formatEta(45), '45 秒');
      expect(formatEta(125), '2 分 5 秒');
    });
  });

  group('DTK 映射', () {
    Map<String, dynamic> videoContent() => <String, dynamic>{
      'platform': 'douyin',
      'kind': 'video',
      'title': '测试作品',
      'author': <String, dynamic>{
        'nickname': '作者甲',
        'avatar': <String, dynamic>{
          'url': 'https://p3.douyinpic.com/avatar.jpg',
        },
      },
      'media': <String, dynamic>{
        'covers': <dynamic>[
          <String, dynamic>{
            'url': 'https://p3.douyinpic.com/cover.jpg',
            'width': 1080,
            'height': 1920,
          },
        ],
        'streams': <dynamic>[
          <String, dynamic>{
            'url': 'https://www.douyin.com/aweme/v1/play/?a=1',
            'width': 1080,
            'height': 1920,
            'bitrate': 2000000,
            'size_bytes': 3000000,
          },
          <String, dynamic>{
            'url': 'https://www.douyin.com/aweme/v1/play/?a=2',
            'width': 720,
            'height': 1280,
            'bitrate': 1000000,
            'size_bytes': 1500000,
          },
          // download_addr：720×720 带烧录水印，必须被丢弃。
          <String, dynamic>{
            'url': 'https://www.douyin.com/aweme/v1/play/?watermark=1',
            'width': 720,
            'height': 720,
            'size_bytes': 5629498,
            'watermark': true,
          },
        ],
      },
      'web_url': 'https://www.douyin.com/video/7300000000000000000',
      'duration_ms': 15000,
    };

    test('视频：标题、来源地址与画质排序', () {
      final ParsedSource source = mapDtkContent(videoContent());
      expect(source.title, '测试作品');
      expect(source.author, '作者甲');
      expect(source.platform, 'douyin');
      expect(
        source.sourceUrl,
        'https://www.douyin.com/video/7300000000000000000',
      );
      expect(source.videoWidth, 1080);
      expect(source.isPortrait, isTrue);
      expect(source.parts.single.durationSeconds, 15);
      expect(source.parts.single.id, source.sourceUrl);
      expect(source.parts.single.streams.length, 2);
      expect(source.parts.single.streams.first.displayLabel, '1080P');
      expect(source.parts.single.streams.first.sizeBytes, 3000000);
      expect(
        source.parts.single.streams.any(
          (MediaStream s) => s.width == 720 && s.height == 720,
        ),
        isFalse,
      );
    });

    test('图文/图集：不抛错、无 part', () {
      final Map<String, dynamic> content = videoContent()
        ..['kind'] = 'image_album';
      (content['media'] as Map<String, dynamic>).remove('streams');
      final ParsedSource source = mapDtkContent(content);
      expect(source.parts, isEmpty);
      expect(source.coverUrl, 'https://p3.douyinpic.com/cover.jpg');
      expect(source.isPortrait, isTrue);
    });
  });

  group('历史记录', () {
    test('旧记录按 sourceUrl 推断平台', () {
      final DownloadTask task = DownloadTask.fromRecord(<String, dynamic>{
        'id': '1',
        'title': '旧抖音记录',
        'sourceUrl': 'https://www.douyin.com/video/123',
        'createdAt': '2026-11-01T10:00:00.000',
      });
      expect(task.platform, '抖音');
      expect(task.sourceUrl, 'https://www.douyin.com/video/123');
      expect(task.isCompleted, isTrue);
    });

    test('显式 platform 不被覆盖', () {
      final DownloadTask task = DownloadTask.fromRecord(<String, dynamic>{
        'id': '2',
        'title': 'B 站记录',
        'platform': '哔哩哔哩',
        'sourceUrl': 'BV1xx411c7mD',
      });
      expect(task.platform, '哔哩哔哩');
    });
  });

  group('登录态工具', () {
    test('sanitizeCookie 只保留登录必需项', () {
      expect(
        AuthStore.sanitizeCookie('SESSDATA=a; bili_jct=b; other=c'),
        'SESSDATA=a; bili_jct=b',
      );
    });

    test('parseSessdataExpiry 解析 URL 编码的过期时间', () {
      final DateTime? expires = AuthStore.parseSessdataExpiry(
        'SESSDATA=abc%2C4102444800%2Cxyz',
      );
      expect(expires?.year, 2100);
    });

    test('无 SESSDATA 或格式异常返回 null', () {
      expect(AuthStore.parseSessdataExpiry(null), isNull);
      expect(AuthStore.parseSessdataExpiry('foo=bar'), isNull);
      expect(AuthStore.parseSessdataExpiry('SESSDATA=plain'), isNull);
    });
  });
}
