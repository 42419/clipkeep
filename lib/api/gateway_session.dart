import 'package:dio/dio.dart';

/// 网页版网关的会话：口令换 cookie，cookie 由浏览器保存（HttpOnly）。
///
/// 口令本身不落任何存储 —— 输一次、换一张 30 天的签名 cookie，之后靠浏览器自动携带。
class GatewaySession {
  GatewaySession({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              // 同源：页面与 /api 都从网关出，不存在 CORS。
              baseUrl: Uri.base.origin,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              validateStatus: (int? status) => status != null && status < 500,
            ),
          );

  final Dio _dio;

  /// 探测是否已登录；网络异常一律当未登录处理。
  Future<bool> isAuthenticated() async {
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(
        '/api/session',
      );
      final dynamic body = response.data;
      return body is Map && body['authenticated'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 换取 cookie。失败时抛出可直接展示的中文原因。
  Future<void> login(String token) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/api/session',
      data: <String, String>{'token': token.trim()},
    );

    final int status = response.statusCode ?? 0;
    if (status == 200) {
      return;
    }
    final dynamic body = response.data;
    final String detail = (body is Map ? '${body['detail'] ?? ''}' : '').trim();
    if (status == 401) {
      throw GatewayAuthException(detail.isEmpty ? '口令不正确' : detail);
    }
    if (status == 429) {
      throw const GatewayAuthException('尝试过于频繁，请稍后再试');
    }
    throw GatewayAuthException(detail.isEmpty ? '登录失败（HTTP $status）' : detail);
  }

  Future<void> logout() async {
    try {
      await _dio.delete<dynamic>('/api/session');
    } catch (_) {
      // 退出失败不影响前端回到登录页。
    }
  }
}

class GatewayAuthException implements Exception {
  const GatewayAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
