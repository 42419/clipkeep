import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipkeep/api/changelog.dart';
import 'package:clipkeep/api/downloader_api.dart';
import 'package:clipkeep/api/dtk_client.dart';
import 'package:clipkeep/api/dtk_mapper.dart';
import 'package:clipkeep/api/update_service.dart';
import 'package:clipkeep/stores/downloader_store.dart';
import 'package:clipkeep/stores/main_tab_controller.dart';
import 'package:clipkeep/stores/settings_store.dart';
import 'package:clipkeep/stores/update_store.dart';
import 'package:clipkeep/utils/media_downloader.dart';
import 'package:clipkeep/utils/media_naming.dart';
import 'package:clipkeep/utils/result.dart';
import 'package:clipkeep/utils/format.dart';
import 'package:clipkeep/viewmodels/download_task.dart';
import 'package:clipkeep/viewmodels/parsed_source.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('qualityLabel', () {
    test('抖音按短边渲染', () {
      expect(qualityLabel(720), '720P');
      expect(qualityLabel(1080), '1080P');
      expect(qualityLabel(1080999), '1080P');
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

  group('文件名', () {
    test('清洗非法字符、控制字符与保留名', () {
      expect(sanitizeNameComponent('a/b\\c:d*e?f"g<h>i|j'), 'abcdefghij');
      expect(sanitizeNameComponent('  a\n\tb  '), 'a b');
      expect(sanitizeNameComponent('CON'), '_CON');
      expect(sanitizeNameComponent('...'), '未命名');
      expect(sanitizeNameComponent(''), '未命名');
      expect(sanitizeNameComponent('一二三四', limit: 2), '一二');
    });

    test('视频文件名与图集文件名', () {
      expect(
        buildVideoStem(
          title: '测试 视频',
          author: 'UP/主',
          publishedAt: '2026-11-09 12:00:00',
          contentId: '7300000000000000001',
          resolution: '1080P60',
          fps: 60,
        ),
        '2026-11-09-视频-UP主-测试 视频-1080P60-60fps-7300000000000000001',
      );
      expect(
        buildAlbumStem(
          title: '图集',
          author: '作者',
          publishedAt: '2026-11-09',
          contentId: '123',
        ),
        '2026-11-09-图集-作者-图集-123',
      );
    });

    test('按字节截断并保留后缀', () {
      final String name = fitFileName('很长的标题' * 40, '-MP.jpg');
      expect(utf8.encode(name).length, lessThanOrEqualTo(240));
      expect(name.endsWith('-MP.jpg'), isTrue);
      expect(name.contains('…'), isTrue);
    });

    test('内容 ID 取链接里的作品 ID', () {
      expect(
        contentIdOf('https://www.douyin.com/video/7300000000000000000'),
        '7300000000000000000',
      );
      expect(contentIdOf(''), 'unknown');
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
        'title': '抖音记录',
        'platform': '抖音',
        'sourceUrl': 'https://www.douyin.com/video/7300000000000000001',
      });
      expect(task.platform, '抖音');
    });

    test('仅音频历史记录不再加载', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'download_tasks': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'audio-1',
            'title': '旧音频任务',
            'platform': '抖音',
            'qualityLabel': '仅音频',
            'createdAt': '2026-11-01T10:00:00.000',
            'status': 'completed',
            'audioOnly': true,
          },
          <String, dynamic>{
            'id': 'video-1',
            'title': '正常任务',
            'platform': '抖音',
            'qualityLabel': '720P',
            'createdAt': '2026-11-01T10:00:00.000',
            'status': 'completed',
          },
        ]),
      });
      final DownloaderStore store = DownloaderStore(_RetryApi());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.tasks.map((DownloadTask t) => t.id), <String>['video-1']);
    });
  });

  group('解析服务凭证', () {
    test('写入后重启仍保留，主动清空后不回退默认值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final SettingsStore store = SettingsStore();
      await store.load();
      expect(store.dtkConfigured, isFalse);

      await store.setDtkBaseUrl('https://dtk.example.com/');
      await store.setDtkApiKey('test-key');
      expect(store.dtkConfigured, isTrue);

      final SettingsStore reloaded = SettingsStore();
      await reloaded.load();
      expect(reloaded.dtkBaseUrl, 'https://dtk.example.com/');
      expect(reloaded.dtkApiKey, 'test-key');
      expect(reloaded.dtkConfigured, isTrue);

      await reloaded.setDtkBaseUrl('');
      await reloaded.setDtkApiKey('');
      final SettingsStore cleared = SettingsStore();
      await cleared.load();
      expect(cleared.dtkBaseUrl, isEmpty);
      expect(cleared.dtkApiKey, isEmpty);
      expect(cleared.dtkConfigured, isFalse);
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

    test('实况视频没有可用地址时不视为实况', () {
      const MediaImage img = MediaImage(
        urls: <String>['https://p3.douyinpic.com/a.jpg'],
        liveVideo: MediaStream(
          kind: 'video',
          quality: 0,
          codec: 'h264',
          urls: <String>[],
          headers: <String, String>{},
        ),
      );
      expect(img.isLive, isFalse);
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
      id: '7300000000000000001',
      title: '测试',
      durationSeconds: 10,
      streams: <MediaStream>[
        MediaStream(
          kind: 'video',
          quality: 720,
          codec: 'avc',
          urls: <String>['https://example.com/720.mp4'],
          headers: <String, String>{},
          bandwidth: 1000,
        ),
        MediaStream(
          kind: 'video',
          quality: 1080,
          codec: 'avc',
          urls: <String>['https://example.com/1080.mp4'],
          headers: <String, String>{},
          bandwidth: 2000,
        ),
      ],
    );

    test('指定画质存在时精确命中', () {
      expect(part.pickVideoQuality(1080)?.quality, 1080);
    });

    test('刷新后指定画质不存在时不静默换档', () {
      expect(part.pickVideoQuality(999), isNull);
    });

    test('多音轨时选最高码率', () {
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
            quality: 128000,
            codec: 'avc',
            urls: <String>['https://example.com/aac'],
            headers: <String, String>{},
          ),
        ],
      );
      expect(audioPart.pickAudio()?.quality, 128000);
    });

    test('同画质重试才允许复用临时分片', () {
      const MediaPart same = MediaPart(
        id: '7300000000000000001',
        title: '测试',
        durationSeconds: 10,
        streams: <MediaStream>[
          MediaStream(
            kind: 'video',
            quality: 720,
            codec: 'avc',
            urls: <String>['https://example.com/720-new.mp4'],
            headers: <String, String>{},
            bandwidth: 1000,
          ),
          MediaStream(
            kind: 'video',
            quality: 1080,
            codec: 'avc',
            urls: <String>['https://example.com/1080-new.mp4'],
            headers: <String, String>{},
            bandwidth: 2000,
          ),
        ],
      );
      const MediaPart changed = MediaPart(
        id: '7300000000000000001',
        title: '测试',
        durationSeconds: 10,
        streams: <MediaStream>[
          MediaStream(
            kind: 'video',
            quality: 1080,
            codec: 'avc',
            urls: <String>['https://example.com/1080-new.mp4'],
            headers: <String, String>{},
            bandwidth: 2000,
          ),
        ],
      );
      const MediaPart differentCodec = MediaPart(
        id: '7300000000000000001',
        title: '测试',
        durationSeconds: 10,
        streams: <MediaStream>[
          MediaStream(
            kind: 'video',
            quality: 720,
            codec: 'hevc',
            urls: <String>['https://example.com/720-hevc.mp4'],
            headers: <String, String>{},
            bandwidth: 1000,
          ),
        ],
      );
      expect(part.sameDownloadSelection(same, videoQuality: 720), isTrue);
      expect(part.sameDownloadSelection(changed, videoQuality: 720), isFalse);
      expect(part.sameDownloadSelection(changed, videoQuality: 1080), isTrue);
      expect(
        part.sameDownloadSelection(differentCodec, videoQuality: 720),
        isFalse,
      );
    });
  });

  group('任务持久化', () {
    test('未完成任务保留 ID/画质/选项，重启后流需重新拉取', () {
      final DownloadTask task = DownloadTask(
        id: 'task-1',
        title: '下载任务测试',
        platform: '抖音',
        qualityLabel: '1080P',
        createdAt: DateTime(2026, 11, 7),
        part: const MediaPart(
          id: '7300000000000000001',
          title: '测试作品',
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
      expect(restored.part?.id, '7300000000000000001');
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

    test('排队任务重启后转为暂停，文件名与保存列表可恢复', () {
      final DownloadTask task = DownloadTask(
        id: 'queued',
        title: '排队任务',
        platform: '抖音',
        qualityLabel: '1080P',
        createdAt: DateTime(2026, 11, 10),
        status: DownloadStatus.queued,
        fileStem: '2026-11-10-视频-作者-标题-1080P-7300000000000000001',
        savedNames: const <String>['a.mp4'],
      );
      final DownloadTask restored = DownloadTask.fromRecord(task.toRecord());
      expect(restored.status, DownloadStatus.paused);
      expect(restored.fileStem, task.fileStem);
      expect(restored.savedNames, <String>['a.mp4']);
    });
  });

  group('下载探测与重试', () {
    test('probeSelectionTotal 汇总视频和音轨总长度', () async {
      final _RangeAdapter adapter = _RangeAdapter();
      final MediaDownloader media = MediaDownloader(
        dio: Dio()..httpClientAdapter = adapter,
      );
      const MediaPart part = MediaPart(
        id: '7300000000000000001',
        title: '测试',
        durationSeconds: 1,
        streams: <MediaStream>[
          MediaStream(
            kind: 'video',
            quality: 720,
            codec: 'avc',
            urls: <String>['https://example.com/v'],
            headers: <String, String>{},
            bandwidth: 1000,
          ),
          MediaStream(
            kind: 'audio',
            quality: 128000,
            codec: '',
            urls: <String>['https://example.com/a'],
            headers: <String, String>{},
            bandwidth: 128,
          ),
        ],
      );
      expect(await media.probeSelectionTotal(part, videoQuality: 720), 1200);
    });

    test('retryTask 防重入，只发起一次刷新', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _RetryApi api = _RetryApi();
      final DownloaderStore store = DownloaderStore(api);
      final DownloadTask task = DownloadTask(
        id: 'retry-test',
        title: '测试',
        platform: '抖音',
        qualityLabel: '720P',
        createdAt: DateTime(2026, 11, 8),
        part: const MediaPart(
          id: '7300000000000000001',
          title: '测试',
          durationSeconds: 1,
          streams: <MediaStream>[
            MediaStream(
              kind: 'video',
              quality: 720,
              codec: 'avc',
              urls: <String>['https://example.com/v'],
              headers: <String, String>{},
              bandwidth: 1000,
            ),
          ],
        ),
        videoQuality: 720,
        status: DownloadStatus.failed,
        totalBytes: 1000,
      );
      final Future<void> first = store.retryTask(task);
      final Future<void> second = store.retryTask(task);
      api.gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(api.refreshCalls, 1);
    });
  });

  group('解析服务连接检测', () {
    test('地址带路径前缀、根路径没有 /healthz 时仍判定为正常', () async {
      final List<String> requests = <String>[];
      final HttpServer server = await _startStub(requests, (
        HttpRequest request,
        HttpResponse response,
      ) async {
        if (request.method == 'POST' &&
            request.uri.path == '/dtk/api/v1/parse') {
          // 真实 DTK 对 example.com 的回答：400 + 标准错误信封。
          response.statusCode = 400;
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode(<String, Object?>{
              'success': false,
              'data': null,
              'error': <String, String>{
                'code': 'INVALID_URL',
                'message': '不是支持的链接',
              },
              'meta': <String, String>{'request_id': 'test'},
            }),
          );
        } else {
          response.statusCode = 404;
        }
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final DtkClient client = DtkClient(
        DtkConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/dtk',
          apiKey: 'dtk_test',
        ),
      );
      final Result<String> result = await client.check();

      expect(result, isA<Ok<String>>());
      expect((result as Ok<String>).value, '连接正常');
      // 根路径的 /healthz 不再被访问：前缀部署下它本来就不存在。
      expect(
        requests.where((String request) => request.endsWith('/healthz')),
        isEmpty,
      );
    });

    test('Key 被拒时给出明确原因', () async {
      final HttpServer server = await _startStub(<String>[], (
        HttpRequest request,
        HttpResponse response,
      ) async {
        response.statusCode = 401;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode(<String, Object?>{
            'success': false,
            'data': null,
            'error': <String, String>{
              'code': 'UNAUTHORIZED',
              'message': 'missing or invalid API key',
            },
            'meta': <String, String>{'request_id': 'test'},
          }),
        );
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final DtkClient client = DtkClient(
        DtkConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'dtk_test',
        ),
      );
      final Result<String> result = await client.check();

      expect(result, isA<Err<String>>());
      expect((result as Err<String>).error.message, 'API Key 无效或缺失');
    });

    test('重定向不当作连接正常', () async {
      final HttpServer server = await _startStub(<String>[], (
        HttpRequest request,
        HttpResponse response,
      ) async {
        response.statusCode = 301;
        response.headers.set('location', 'https://example.com/');
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final DtkClient client = DtkClient(
        DtkConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/dtk',
          apiKey: 'dtk_test',
        ),
      );
      final Result<String> result = await client.check();

      expect(result, isA<Err<String>>());
      expect((result as Err<String>).error.message, contains('重定向'));
    });
  });

  group('更新日志解析', () {
    test('按版本块切分，跳过 Unreleased 与说明性标题', () {
      const String text = '''
# 更新日志

## [Unreleased]

暂无。

## [1.1.1] - 2026-11-10

<!-- meta: versionCode=2 release=android-build-70 -->

### 新增
- 检查更新
- 更新日志页

## [1.1.0] - 2026-11-08

### 修复
- 修了个 bug

---

## App 解析约定

### 1. 版本块格式

这段正文不应被当成条目。
''';
      final Changelog log = Changelog.parse(text);
      expect(log.entries.length, 2);
      expect(log.entries.first.versionName, '1.1.1');
      expect(log.entries.first.date, '2026-11-10');
      expect(log.entries.first.sections.single.title, '新增');
      expect(log.entries.first.sections.single.items, <String>[
        '检查更新',
        '更新日志页',
      ]);
      expect(log.entries.last.versionName, '1.1.0');
      expect(log.entries.last.sections.single.items, <String>['修了个 bug']);
      expect(log.entryFor('1.1.0')?.versionName, '1.1.0');
      expect(log.entryFor('9.9.9'), isNull);
    });

    test('空文档与只有 Unreleased 时不产生版本块', () {
      expect(Changelog.parse('').entries, isEmpty);
      expect(Changelog.parse('## [Unreleased]\n\n暂无。').entries, isEmpty);
    });
  });

  group('更新清单', () {
    const Map<String, dynamic> json = <String, dynamic>{
      'versionName': '1.1.1',
      'versionCode': 2,
      'publishedAt': '2026-11-10',
      'release': 'android-build-70',
      'apks': <String, dynamic>{
        'arm64-v8a': <String, dynamic>{
          'asset': 'app-arm64-v8a-release.apk',
          'size': 1024,
          'sha256': 'AA',
          'versionCode': 2009,
        },
        'x86_64': <String, dynamic>{
          'asset': 'app-x86_64-release.apk',
          'size': 2048,
          'sha256': 'BB',
          'url': 'https://example.com/x.apk',
        },
      },
    };

    test('解析字段、统一小写并比较版本', () {
      final UpdateInfo info = UpdateInfo.fromJson(json);
      expect(info.versionName, '1.1.1');
      expect(info.versionCode, 2);
      expect(info.publishedAt, '2026-11-10');
      expect(info.release, 'android-build-70');
      expect(info.isNewerThan('1.1.0', 1), isTrue);
      expect(info.isNewerThan('1.1.1', 2), isFalse);
      expect(info.apks['arm64-v8a']?.sha256, 'aa');
      expect(info.apks['arm64-v8a']?.size, 1024);
      expect(info.apks['arm64-v8a']?.versionCode, 2009);
      expect(info.apks['x86_64']?.versionCode, 0);
    });

    test('按设备 ABI 优先级匹配，缺失时回退 arm64', () {
      final UpdateInfo info = UpdateInfo.fromJson(json);
      expect(
        info.apkFor(<String>['x86_64', 'arm64-v8a'])?.asset,
        'app-x86_64-release.apk',
      );
      expect(
        info.apkFor(<String>['armeabi-v7a'])?.asset,
        'app-arm64-v8a-release.apk',
      );
      expect(
        info.apkFor(<String>['riscv64'])?.asset,
        'app-arm64-v8a-release.apk',
      );
    });

    test('语义化版本比较', () {
      expect(compareVersionNames('1.1.1', '1.1.0'), 1);
      expect(compareVersionNames('1.1.0', '1.1.1'), -1);
      expect(compareVersionNames('1.1.0', '1.1.0'), 0);
      expect(compareVersionNames('1.10.0', '1.9.9'), 1);
      expect(compareVersionNames('2.0', '2.0.0'), 0);
    });

    test('本地 versionCode 更大时仍按版本名判断', () {
      final UpdateInfo info = UpdateInfo.fromJson(json);
      // 线上 1.1.1(2) vs 本地 1.1.0(2001)：版本名更高，应判定有更新。
      expect(info.isNewerThan('1.1.0', 2001), isTrue);
      // 版本名相同且本地 code 更大：无更新。
      expect(info.isNewerThan('1.1.1', 2001), isFalse);
      // 本地版本更高：无更新。
      expect(info.isNewerThan('1.1.2', 3), isFalse);
    });

    test('清单里写了直链时保留直链', () {
      final UpdateInfo info = UpdateInfo.fromJson(json);
      expect(info.apks['x86_64']?.url, 'https://example.com/x.apk');
      expect(info.apks['arm64-v8a']?.url, isNull);
    });

    test('urls 数组按优先级保留并去重', () {
      final UpdateInfo info = UpdateInfo.fromJson(<String, dynamic>{
        'versionName': '1.1.2',
        'versionCode': 6,
        'release': 'v1.1.2',
        'apks': <String, dynamic>{
          'arm64-v8a': <String, dynamic>{
            'asset': 'app-arm64-v8a-release.apk',
            'urls': <String>[
              'https://cnb.cool/a.apk',
              'https://github.com/a.apk',
              'https://cnb.cool/a.apk',
            ],
          },
        },
      });
      expect(info.apks['arm64-v8a']?.downloadUrls, <String>[
        'https://cnb.cool/a.apk',
        'https://github.com/a.apk',
      ]);
    });
  });

  group('自动检查更新', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'ClipKeep',
        packageName: 'top.yunov.clipkeep',
        version: '1.1.5',
        buildNumber: '2009',
        buildSignature: '',
      );
    });

    test('有更新时提示，忽略后不再提醒', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _FakeUpdateService service = _FakeUpdateService();
      final UpdateStore store = UpdateStore(service: service);
      await store.load();
      await store.check();
      expect(store.hasUpdate, isTrue);
      expect(store.shouldNotify, isTrue);
      expect(store.pendingPrompt, '1.1.6');
      await store.markPrompted();
      expect(store.pendingPrompt, isNull);
      await store.ignoreCurrent();
      expect(store.shouldNotify, isFalse);
      expect(store.hasUpdate, isTrue);
      await store.clearIgnored();
      expect(store.shouldNotify, isTrue);
    });

    test('一天内不重复自动检查', () async {
      final DateTime now = DateTime(2026, 11, 12, 15);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_last_check': now
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      final _FakeUpdateService service = _FakeUpdateService();
      final UpdateStore store = UpdateStore(service: service, clock: () => now);
      await store.checkIfDue();
      expect(service.calls, 0);
      await store.check();
      expect(service.calls, 1);
    });
    test('重启后按缓存版本名继续提示', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'update_latest_version': '1.1.6',
        'update_last_check': DateTime(2026, 11, 12, 14).millisecondsSinceEpoch,
      });
      final _FakeUpdateService service = _FakeUpdateService();
      final UpdateStore store = UpdateStore(
        service: service,
        clock: () => DateTime(2026, 11, 12, 15),
      );
      await store.checkIfDue();
      expect(service.calls, 0);
      expect(store.hasUpdate, isTrue);
      expect(store.shouldNotify, isTrue);
    });
  });
}

class _FakeUpdateService extends UpdateService {
  int calls = 0;

  @override
  Future<Result<UpdateInfo>> check() async {
    calls += 1;
    return const Ok<UpdateInfo>(
      UpdateInfo(
        versionName: '1.1.6',
        versionCode: 10,
        publishedAt: '2026-11-13',
        release: 'v1.1.6',
        apks: <String, UpdateApk>{},
      ),
    );
  }
}

class _RangeAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bool audio = options.uri.path.endsWith('/a');
    return ResponseBody.fromString(
      '',
      206,
      headers: <String, List<String>>{
        'content-range': <String>['bytes 0-0/${audio ? 200 : 1000}'],
        'content-type': <String>['video/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RetryApi extends DownloaderApi {
  final Completer<void> gate = Completer<void>();
  int refreshCalls = 0;

  @override
  Future<Result<List<MediaStream>>> refreshStreams(MediaPart part) async {
    refreshCalls += 1;
    await gate.future;
    return const Ok<List<MediaStream>>(<MediaStream>[
      MediaStream(
        kind: 'video',
        quality: 720,
        codec: 'avc',
        urls: <String>['https://example.com/v'],
        headers: <String, String>{},
        bandwidth: 1000,
      ),
    ]);
  }

  @override
  Future<void> cleanup(String downloadId) async {}

  @override
  Future<void> cleanupOrphans(Set<String> keepIds) async {}

  @override
  Future<int?> probeSelectionTotal(MediaPart part, {int? videoQuality}) async =>
      1000;

  @override
  Future<Result<String>> download(
    MediaPart part, {
    int? videoQuality,
    bool coverOnly = false,
    bool saveCover = false,
    String? coverUrl,
    String? downloadId,
    String? fileStem,
    CancelToken? cancelToken,
    void Function(DownloadProgress progress)? onProgress,
    void Function(List<SavedMediaFile> files)? onSavedFiles,
  }) async => const Ok<String>('done');

  @override
  Future<String?> cacheCover(String? coverUrl, String id) async => null;
}

/// 起一个本地 HTTP 桩服务，记录请求行供断言。
Future<HttpServer> _startStub(
  List<String> requests,
  Future<void> Function(HttpRequest request, HttpResponse response) handler,
) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}');
    await handler(request, request.response);
  });
  return server;
}
