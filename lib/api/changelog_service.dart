import 'package:dio/dio.dart';

import '../utils/result.dart';
import 'changelog.dart';

/// 拉取仓库根目录的 CHANGELOG.md。
class ChangelogService {
  ChangelogService({
    Dio? dio,
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
  final String url;

  Future<Result<Changelog>> fetch() async {
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
          code == null ? '获取更新日志失败：${e.type.name}' : '获取更新日志失败（HTTP $code）',
        ),
      );
    } catch (e) {
      return Err(AppError('获取更新日志失败：$e'));
    }
  }
}
