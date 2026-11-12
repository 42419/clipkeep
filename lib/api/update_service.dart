import 'dart:convert';

import 'package:dio/dio.dart';

import '../constants/app_constants.dart';
import '../utils/result.dart';

/// 单个 ABI 的安装包信息。
class UpdateApk {
  const UpdateApk({
    required this.asset,
    required this.size,
    required this.sha256,
    this.url,
    this.urls = const <String>[],
  });

  /// Release 资产名，如 `app-arm64-v8a-release.apk`。
  final String asset;

  /// 字节数，用于下载进度与磁盘预检。
  final int size;

  /// 小写十六进制 SHA-256，下载后校验。
  final String sha256;

  /// 单一直链；兼容旧清单。
  final String? url;

  /// 按优先级排列的下载直链（CNB 在前，GitHub 在后）。
  final List<String> urls;

  /// 去重后的下载顺序：`url` 优先，其次 `urls`。
  List<String> get downloadUrls {
    final List<String> result = <String>[];
    final Set<String> seen = <String>{};
    for (final String item in <String>[?url, ...urls]) {
      final String value = item.trim();
      if (value.isNotEmpty && seen.add(value)) {
        result.add(value);
      }
    }
    return result;
  }

  factory UpdateApk.fromJson(Map<String, dynamic> json) {
    final List<String> parsedUrls = <String>[];
    final dynamic rawUrls = json['urls'];
    if (rawUrls is List) {
      for (final dynamic item in rawUrls) {
        if (item is String) {
          parsedUrls.add(item);
        } else if (item is Map) {
          final String value = (item['url'] ?? '').toString();
          if (value.isNotEmpty) {
            parsedUrls.add(value);
          }
        }
      }
    }
    return UpdateApk(
      asset: (json['asset'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] ?? '').toString().toLowerCase(),
      url: json['url']?.toString(),
      urls: parsedUrls,
    );
  }

  UpdateApk withUrls(List<String> values) {
    final List<String> unique = <String>[];
    final Set<String> seen = <String>{};
    for (final String item in values) {
      final String value = item.trim();
      if (value.isNotEmpty && seen.add(value)) {
        unique.add(value);
      }
    }
    return UpdateApk(
      asset: asset,
      size: size,
      sha256: sha256,
      url: unique.isEmpty ? null : unique.first,
      urls: unique,
    );
  }
}

/// 远端发布信息，对应仓库的 `update.json`。
class UpdateInfo {
  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.publishedAt,
    required this.release,
    required this.apks,
  });

  final String versionName;

  /// 单调递增的版本号，比较只看它。
  final int versionCode;

  /// 发布日期（YYYY-MM-DD）。
  final String publishedAt;

  /// 该版本对应的 GitHub Release tag。
  final String release;

  /// ABI -> 安装包。
  final Map<String, UpdateApk> apks;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> rawApks =
        (json['apks'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    return UpdateInfo(
      versionName: (json['versionName'] ?? '').toString(),
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      publishedAt: (json['publishedAt'] ?? '').toString(),
      release: (json['release'] ?? '').toString(),
      apks: <String, UpdateApk>{
        for (final MapEntry<String, dynamic> entry in rawApks.entries)
          if (entry.value is Map)
            entry.key: UpdateApk.fromJson(
              (entry.value as Map).cast<String, dynamic>(),
            ),
      },
    );
  }

  /// 是否比本地安装的版本更新。
  ///
  /// 先比 `versionName`（语义化版本），相同再比 `versionCode`。这样即使本地
  /// 装的是 versionCode 更大的自构建（如 `1.1.0 (2001)`），也能正确发现
  /// 线上的 `1.1.1`。
  bool isNewerThan(String currentVersionName, int currentVersionCode) {
    final int byName = compareVersionNames(versionName, currentVersionName);
    if (byName != 0) {
      return byName > 0;
    }
    return versionCode > currentVersionCode;
  }

  /// 按设备 ABI 优先级挑安装包；都不匹配时回退 arm64-v8a。
  UpdateApk? apkFor(List<String> supportedAbis) {
    for (final String abi in supportedAbis) {
      final UpdateApk? apk = apks[abi];
      if (apk != null) {
        return apk;
      }
    }
    return apks['arm64-v8a'];
  }
}

/// 比较两个语义化版本号（`1.10.0` > `1.9.9`）。
///
/// 逐段按数字比较，缺失的段按 0 处理；无法解析的段也按 0。
int compareVersionNames(String a, String b) {
  List<int> parse(String value) {
    return value
        .trim()
        .split('.')
        .map((String part) => int.tryParse(part) ?? 0)
        .toList();
  }

  final List<int> left = parse(a);
  final List<int> right = parse(b);
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i++) {
    final int l = i < left.length ? left[i] : 0;
    final int r = i < right.length ? right[i] : 0;
    if (l != r) {
      return l.compareTo(r);
    }
  }
  return 0;
}

/// 检查更新失败。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 检查更新：CNB 为主源，GitHub 为保底。
///
/// 清单来源优先级：
/// 1. 构建期注入的 `UPDATE_MANIFEST_URL`（自定义源；失败会继续走主源）
/// 2. CNB `releases/latest/download/update.json`
/// 3. GitHub `releases/latest` 里的 `update.json` 资产
class UpdateService {
  UpdateService({
    Dio? dio,
    this.manifestUrl = AppConstants.updateManifestUrl,
    this.repo = AppConstants.githubRepo,
    this.cnbRepo = AppConstants.cnbRepo,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 6),
               receiveTimeout: const Duration(seconds: 15),
               headers: const <String, String>{
                 'accept': 'application/json',
                 'user-agent': 'ClipKeep-Android',
               },
             ),
           );

  final Dio _dio;
  final String manifestUrl;
  final String repo;
  final String cnbRepo;

  /// 拉取最新发布信息；网络或格式异常统一转成 [Err]。
  Future<Result<UpdateInfo>> check() async {
    try {
      UpdateInfo info;
      if (manifestUrl.trim().isNotEmpty) {
        try {
          info = await _fromManifestUrl(manifestUrl.trim());
        } catch (_) {
          info = await _fromPrimary();
        }
      } else {
        info = await _fromPrimary();
      }
      if (info.versionCode <= 0 || info.apks.isEmpty) {
        return const Err(AppError('更新清单缺少版本号或安装包信息'));
      }
      return Ok(info);
    } on UpdateException catch (e) {
      return Err(AppError(e.message));
    } on DioException catch (e) {
      return Err(AppError('检查更新失败：${_dioMessage(e)}'));
    } catch (e) {
      return Err(AppError('检查更新失败：$e'));
    }
  }

  /// CNB 主源失败后回退 GitHub。
  Future<UpdateInfo> _fromPrimary() async {
    return _fromLatestRelease();
  }

  Future<UpdateInfo> _fromManifestUrl(String url) async {
    final Response<dynamic> response = await _dio.get<dynamic>(url);
    final Map<String, dynamic>? json = _asMap(response.data);
    if (json == null) {
      throw const UpdateException('更新清单格式异常');
    }
    return _resolveAssetUrls(UpdateInfo.fromJson(json));
  }

  Future<UpdateInfo> _fromLatestRelease() async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      'https://api.github.com/repos/$repo/releases/latest',
    );
    return _fromRelease(response.data, cnbFirst: false);
  }

  /// CNB 与 GitHub 的 latest release 结构相近，共用解析。
  Future<UpdateInfo> _fromRelease(
    dynamic data, {
    required bool cnbFirst,
  }) async {
    final Map<String, dynamic>? release = _asMap(data);
    if (release == null) {
      throw const UpdateException('获取最新版本失败');
    }
    final List<dynamic> assets =
        (release['assets'] as List?) ?? const <dynamic>[];
    final Map<String, List<String>> urls = <String, List<String>>{};
    String? manifestUrl;
    for (final dynamic item in assets) {
      final Map<String, dynamic> asset = _asMap(item) ?? <String, dynamic>{};
      final String name = (asset['name'] ?? '').toString();
      final String url = (asset['browser_download_url'] ?? '').toString();
      if (name.isEmpty || url.isEmpty) {
        continue;
      }
      urls.putIfAbsent(name, () => <String>[]).add(url);
      if (name == 'update.json') {
        manifestUrl = url;
      }
    }
    if (manifestUrl == null) {
      throw const UpdateException('该版本未附带更新清单（update.json）');
    }
    final Response<dynamic> manifest = await _dio.get<dynamic>(manifestUrl);
    final Map<String, dynamic>? json = _asMap(manifest.data);
    if (json == null) {
      throw const UpdateException('更新清单格式异常');
    }
    return _resolveAssetUrls(
      UpdateInfo.fromJson(json),
      assetUrls: urls,
      cnbFirst: cnbFirst,
    );
  }

  /// 清单里没写直链时，用 Release 资产名补上；同时补另一平台的镜像。
  UpdateInfo _resolveAssetUrls(
    UpdateInfo info, {
    Map<String, List<String>> assetUrls = const <String, List<String>>{},
    bool cnbFirst = true,
  }) {
    final String tag = info.release.trim();
    final String cnbBase =
        'https://cnb.cool/${AppConstants.cnbRepo}/-/releases/download/$tag';
    final String githubBase = 'https://github.com/$repo/releases/download/$tag';
    final List<String> mirrors = tag.isEmpty
        ? const <String>[]
        : cnbFirst
        ? <String>[cnbBase, githubBase]
        : <String>[githubBase, cnbBase];
    final Map<String, UpdateApk> apks = <String, UpdateApk>{};
    for (final MapEntry<String, UpdateApk> entry in info.apks.entries) {
      final UpdateApk apk = entry.value;
      final List<String> candidates = <String>[
        if (apk.url != null) apk.url!,
        ...apk.urls,
        ...?assetUrls[apk.asset],
        for (final String base in mirrors) '$base/${apk.asset}',
      ];
      apks[entry.key] = apk.withUrls(candidates);
    }
    return UpdateInfo(
      versionName: info.versionName,
      versionCode: info.versionCode,
      publishedAt: info.publishedAt,
      release: info.release,
      apks: apks,
    );
  }

  Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    // 有服务端会把 JSON 当字符串返回。
    if (value is String && value.trim().startsWith('{')) {
      try {
        final dynamic decoded = jsonDecode(value);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String _dioMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时，请检查网络';
      case DioExceptionType.receiveTimeout:
        return '等待响应超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      default:
        final int? code = e.response?.statusCode;
        if (code == 404) {
          return '还没有已发布的版本';
        }
        return code == null ? (e.message ?? '网络错误') : 'HTTP $code';
    }
  }
}
