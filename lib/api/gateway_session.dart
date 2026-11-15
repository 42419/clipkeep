import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import '../utils/web_api.dart';

/// 会话失效通知：web 上任意同源请求拿到 401 就自增，登录闸门据此退回登录页。
///
/// cookie 有 30 天有效期，过期后页面不会自己知道；把「有请求被拒」当成信号，
/// 比等到用户点解析再看到一句错误文案更接近真实原因。
final ValueNotifier<int> gatewayAuthEpoch = ValueNotifier<int>(0);

void markGatewaySessionExpired() {
  gatewayAuthEpoch.value += 1;
}

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
              baseUrl: webApiRoot(),
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              // 5xx 也交给下面统一翻译，别让 DioException 的原始英文漏到界面上。
              validateStatus: (int? status) => status != null && status < 600,
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
    try {
      final Response<dynamic> response = await _dio.post<dynamic>(
        '/api/session',
        data: <String, String>{'token': token.trim()},
      );
      _throwIfFailed(response.statusCode ?? 0, _detail(response.data));
    } on DioException catch (error) {
      // 注入的 Dio 可能用默认 validateStatus，4xx/5xx 会走异常分支；
      // 有响应就先按状态码翻译，避免把 DioException 的英文抛给界面。
      final Response<dynamic>? response = error.response;
      if (response != null) {
        _throwIfFailed(response.statusCode ?? 0, _detail(response.data));
      }
      throw GatewayAuthException(_networkMessage(error));
    }
  }

  /// 2xx 之外的状态码统一翻译成中文；[detail] 优先，网关的文案更具体。
  void _throwIfFailed(int status, String detail) {
    if (status >= 200 && status < 300) {
      return;
    }
    if (status == 401) {
      throw GatewayAuthException(detail.isEmpty ? '口令不正确' : detail);
    }
    if (status == 429) {
      throw const GatewayAuthException('尝试过于频繁，请稍后再试');
    }
    if (status >= 500) {
      throw GatewayAuthException(
        detail.isEmpty ? '网关暂时不可用（HTTP $status），请稍后再试' : detail,
      );
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

  String _detail(dynamic body) =>
      (body is Map ? '${body['detail'] ?? ''}' : '').trim();

  String _networkMessage(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return '连接网关超时，请稍后再试';
      case DioExceptionType.receiveTimeout:
        return '网关响应超时，请稍后再试';
      case DioExceptionType.connectionError:
        return '无法连接网关，请检查网络后重试';
      default:
        return '登录失败，请稍后再试';
    }
  }
}

class GatewayAuthException implements Exception {
  const GatewayAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
