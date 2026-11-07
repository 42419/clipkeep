import 'package:clipkeep/api/dtk_mapper.dart';
import 'package:clipkeep/stores/auth_store.dart';
import 'package:clipkeep/stores/main_tab_controller.dart';
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
    test('点赞计数', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(12400), '1.2w');
      expect(formatCount(124000000), '1.2亿');
    });

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

  group('底部导航', () {
    test('openDownloads 切到下载页并指定已完成分段', () {
      final MainTabController controller = MainTabController();
      controller.openDownloads(section: 1);
      expect(controller.index, 1);
      expect(controller.downloadsSection, 1);
    });

    test('底部导航来回切换不清空下载分段', () {
      final MainTabController controller = MainTabController()
        ..openDownloads(section: 1);
      controller
        ..select(0)
        ..select(1);
      expect(controller.downloadsSection, 1);
      controller.selectDownloads(0);
      expect(controller.downloadsSection, 0);
    });
  });

  group('图文映射', () {
    Map<String, dynamic> album({
      required List<Map<String, dynamic>> images,
      String description = '测试图文',
    }) {
      return <String, dynamic>{
        'kind': 'image_album',
        'platform': 'douyin',
        'content_id': '1234567890123456789',
        'web_url': 'https://www.douyin.com/note/1234567890123456789',
        'description': description,
        'media': <String, dynamic>{
          'covers': <Map<String, dynamic>>[
            <String, dynamic>{
              'url': 'https://p3.douyinpic.com/cover.webp',
              'width': 1080,
              'height': 1920,
            },
          ],
          'streams': <dynamic>[],
          'images': images,
        },
      };
    }

    Map<String, dynamic> image({
      int width = 1080,
      int height = 1920,
      Map<String, dynamic>? video,
    }) {
      return <String, dynamic>{
        'url': 'https://p3.douyinpic.com/a.webp',
        'urls': <String>[
          'https://p3.douyinpic.com/a.webp',
          'https://p9.douyinpic.com/a.webp',
        ],
        'width': width,
        'height': height,
        'video': ?video,
      };
    }

    test('单张静态图按图集返回，不产生视频 part', () {
      final ParsedSource source = mapDtkContent(
        album(images: <Map<String, dynamic>>[image()]),
      );
      expect(source.isImageAlbum, isTrue);
      expect(source.images, hasLength(1));
      expect(source.images.first.isLive, isFalse);
      expect(source.images.first.urls, hasLength(2));
      expect(source.parts, isEmpty);
      expect(source.videoWidth, 1080);
      expect(source.videoHeight, 1920);
    });

    test('实况图保留关联视频与多镜像地址', () {
      final ParsedSource source = mapDtkContent(
        album(
          images: <Map<String, dynamic>>[
            image(
              video: <String, dynamic>{
                'url': 'https://v26.douyinvod.com/live.mp4',
                'urls': <String>['https://v26.douyinvod.com/live.mp4'],
                'width': 720,
                'height': 1280,
                'size_bytes': 249596,
                'watermark': false,
              },
            ),
          ],
        ),
      );
      final MediaImage img = source.images.single;
      expect(img.isLive, isTrue);
      expect(img.liveVideo?.primaryUrl, contains('live.mp4'));
      expect(img.liveVideo?.sizeBytes, 249596);
      expect(img.liveVideo?.width, 720);
    });

    test('多图混合实况图数量正确', () {
      final ParsedSource source = mapDtkContent(
        album(
          images: <Map<String, dynamic>>[
            image(),
            image(
              video: <String, dynamic>{
                'url': 'https://v26.douyinvod.com/live.mp4',
                'width': 720,
                'height': 1280,
              },
            ),
            image(width: 1320, height: 2868),
          ],
        ),
      );
      expect(source.images, hasLength(3));
      expect(source.images.where((MediaImage e) => e.isLive), hasLength(1));
    });

    test('长文案标题截断，但仍是单图图集', () {
      final String longText = '这是一段很长的文字内容' * 12;
      final Map<String, dynamic> content = album(
        images: <Map<String, dynamic>>[image()],
        description: longText,
      );
      content['title'] = longText;
      final ParsedSource source = mapDtkContent(content);
      expect(source.isImageAlbum, isTrue);
      expect(source.title.endsWith('…'), isTrue);
      expect(source.title.length, lessThanOrEqualTo(61));
    });
  });

  group('画质选择', () {
    const MediaPart part = MediaPart(
      id: 'BV-test-1',
      title: '测试',
      durationSeconds: 10,
      streams: <MediaStream>[
        MediaStream(
          kind: 'video',
          quality: 720,
          codec: 'avc',
          urls: <String>['https://example.com/720.mp4'],
          headers: <String, String>{},
        ),
        MediaStream(
          kind: 'video',
          quality: 1080,
          codec: 'avc',
          urls: <String>['https://example.com/1080.mp4'],
          headers: <String, String>{},
        ),
      ],
    );

    test('指定画质存在时精确命中', () {
      expect(part.pickVideoQuality(1080)?.quality, 1080);
    });

    test('刷新后指定画质不存在时不静默换档', () {
      expect(part.pickVideoQuality(999), isNull);
    });

    test('普通音轨优先于 Hi-Res', () {
      const MediaPart audioPart = MediaPart(
        id: 'audio',
        title: 'audio',
        durationSeconds: 1,
        streams: <MediaStream>[
          MediaStream(
            kind: 'audio',
            quality: 30251,
            codec: 'flac',
            urls: <String>['https://example.com/flac'],
            headers: <String, String>{},
          ),
          MediaStream(
            kind: 'audio',
            quality: 30280,
            codec: 'avc',
            urls: <String>['https://example.com/aac'],
            headers: <String, String>{},
          ),
        ],
      );
      expect(audioPart.pickAudio()?.quality, 30280);
    });

    test('仅音频抽轨选最低视频画质', () {
      expect(part.pickSmallestVideo()?.quality, 720);
    });
  });

  group('任务持久化', () {
    test('未完成任务保留 ID/画质/选项，重启后流需重新拉取', () {
      final DownloadTask task = DownloadTask(
        id: 'task-1',
        title: '多 P 测试',
        platform: '哔哩哔哩',
        qualityLabel: '1080P',
        createdAt: DateTime(2026, 11, 7),
        part: const MediaPart(
          id: 'BV1xx411c7mD-12345',
          title: 'P2',
          durationSeconds: 60,
          streams: <MediaStream>[],
        ),
        videoQuality: 1080,
        saveCover: true,
        status: DownloadStatus.paused,
        progress: 0.42,
      );
      final DownloadTask restored = DownloadTask.fromRecord(task.toRecord());
      expect(restored.status, DownloadStatus.paused);
      expect(restored.part?.id, 'BV1xx411c7mD-12345');
      expect(restored.part?.streams, isEmpty);
      expect(restored.videoQuality, 1080);
      expect(restored.saveCover, isTrue);
      expect(restored.progress, closeTo(0.42, 0.001));
    });

    test('旧记录没有 status 时按已完成兼容', () {
      final DownloadTask restored = DownloadTask.fromRecord(<String, dynamic>{
        'id': 'old',
        'title': '旧记录',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      });
      expect(restored.status, DownloadStatus.completed);
      expect(restored.progress, 1);
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
