import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../utils/result.dart';
import 'changelog.dart';

/// 拉取仓库根目录的 CHANGELOG.md。
class ChangelogService {
  ChangelogService({
    Dio? dio,
    this.assetPath = 'CHANGELOG.md',
    this.url =
        'https://raw.githubusercontent.com/42419/clipkeep/main/CHANGELOG.md',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 6),
               receiveTimeout: const Duration(seconds: 15),
               headers: const <String, String>{
                 'user-agent': 'ClipKeep-Android',
               },
             ),
           );

  final Dio _dio;
  final String assetPath;
  final String url;

  Future<Result<Changelog>> fetch() async {
    // 优先读 APK 内置的 CHANGELOG.md，离线也能看，且不受网络波动影响。
    try {
      final String text = await rootBundle.loadString(assetPath);
      if (text.trim().isNotEmpty) {
        return Ok(Changelog.parse(text));
      }
    } catch (_) {
      // 资源缺失时回退远端，兼容旧构建。
    }
    try {
      final Response<String> response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final String? text = response.data;
      if (text == null || text.trim().isEmpty) {
        return const Err(AppError('更新日志为空'));
      }
      return Ok(Changelog.parse(text));
    } on DioException catch (e) {
      final int? code = e.response?.statusCode;
      return Err(
        AppError(
          code == null ? '读取更新日志失败：${e.type.name}' : '读取更新日志失败（HTTP $code）',
        ),
      );
    } catch (e) {
      return Err(AppError('读取更新日志失败：$e'));
    }
  }
}
