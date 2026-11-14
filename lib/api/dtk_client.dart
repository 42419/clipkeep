import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../utils/result.dart';
import '../viewmodels/parsed_source.dart';
import 'dtk_mapper.dart';

/// 抖音解析服务（DTK）连接配置。
class DtkConfig {
  const DtkConfig({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  String get normalizedBase {
    String base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// web 版由网关代持 Key，前端只需要同源地址。
  bool get isConfigured =>
      normalizedBase.isNotEmpty && (kIsWeb || apiKey.trim().isNotEmpty);
}

/// DTK 业务/网络错误。
class DtkException implements Exception {
  DtkException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// DTK REST 客户端：只负责「解析取直链」，下载由 App 自己完成。
class DtkClient {
  DtkClient(this.config)
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
          // 不自动跟随重定向：X-API-Key 不能带到未知第三方地址。
          followRedirects: false,
          headers: const <String, String>{
            'accept': 'application/json',
            'content-type': 'application/json',
          },
          validateStatus: (int? status) => status != null && status < 600,
        ),
      );

  final DtkConfig config;
  final Dio _dio;

  String get _base => config.normalizedBase;

  Map<String, String> get _authHeaders => <String, String>{
    // web 上不发 Key：网关用 cookie 鉴权，Key 永不出服务器。
    if (!kIsWeb && config.apiKey.trim().isNotEmpty)
      'X-API-Key': config.apiKey.trim(),
  };

  /// 解析抖音链接/分享文案，返回可下载来源。
  Future<Result<ParsedSource>> parse(String input) async {
    try {
      final Map<String, dynamic> first = await _submitParse(
        input,
        refresh: false,
      );
      return await _resolveTask(first);
    } on DtkException catch (e) {
      return Err(AppError(e.message, cause: e));
    } catch (e) {
      return Err(AppError('抖音解析失败：${_netMessage(e)}', cause: e));
    }
  }

  /// 重新解析取最新直链（下载失败重试时用）。
  Future<Result<List<MediaStream>>> refreshStreams(String webUrl) async {
    try {
      final Map<String, dynamic> first = await _submitParse(
        webUrl,
        refresh: true,
      );
      final Result<ParsedSource> mapped = await _resolveTask(first);
      if (mapped is Ok<ParsedSource>) {
        final List<MediaPart> parts = mapped.value.parts;
        if (parts.isEmpty || parts.first.streams.isEmpty) {
          return const Err(AppError('刷新下载地址失败：没有可用视频流'));
        }
        return Ok(parts.first.streams);
      }
      return Err((mapped as Err<ParsedSource>).error);
    } on DtkException catch (e) {
      return Err(AppError(e.message, cause: e));
    } catch (e) {
      return Err(AppError('刷新下载地址失败：${_netMessage(e)}', cause: e));
    }
  }

  /// 测试连通性与 Key 有效性（用一个必然被拒的 host，不消耗身份）。
  ///
  /// 不再先探根路径的 `/healthz`：地址可能带路径前缀（如 `https://host/dtk`），
  /// 也可能前面挂了同源网关，`/healthz` 未必存在，404 并不代表服务不可用。
  /// parse 探针本身就能同时验证地址、TLS、Key 与信封格式。
  Future<Result<String>> check() async {
    if (!config.isConfigured) {
      return const Err(AppError('未内置抖音解析服务（地址或 Key 缺失，需构建时注入）'));
    }
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '$_base/api/v1/parse',
        queryParameters: <String, dynamic>{'wait': 0, 'lang': 'zh'},
        data: <String, dynamic>{'url': 'https://example.com/'},
        options: Options(headers: _authHeaders),
      );
      final int status = resp.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        return Err(AppError('解析服务发生重定向（HTTP $status），请使用最终地址并改用 HTTPS'));
      }
      if (status == 401) {
        return const Err(AppError('API Key 无效或缺失'));
      }
      if (status == 403) {
        return const Err(AppError('API Key 权限不足'));
      }
      if (status == 429) {
        return const Err(AppError('请求过于频繁（触发限流）'));
      }
      final dynamic body = resp.data;
      if (body is! Map) {
        return Err(AppError('服务返回非 JSON 响应（HTTP $status），请确认地址指向 DTK API'));
      }
      final Map<String, dynamic> envelope = Map<String, dynamic>.from(body);
      final bool looksLikeEnvelope =
          envelope.containsKey('success') ||
          envelope.containsKey('data') ||
          envelope.containsKey('error');
      if (!looksLikeEnvelope) {
        return Err(AppError('服务返回格式不匹配（HTTP $status）'));
      }
      if (status >= 500) {
        return Err(AppError(_envelopeError(envelope)));
      }
      if (envelope['success'] != true) {
        final String code = (_envelopeCode(envelope) ?? '').toLowerCase();
        if (code.contains('auth') ||
            code.contains('key') ||
            code.contains('unauthorized') ||
            code.contains('forbidden')) {
          return Err(
            AppError('API Key 无效或权限不足（${code.isEmpty ? status : code}）'),
          );
        }
      }
      // 能拿到标准信封即说明地址与 Key 可用（业务错误如 INVALID_URL 不算失败）。
      return const Ok('连接正常');
    } on DioException catch (e) {
      return Err(AppError('连接失败：${_dioMessage(e)}'));
    } catch (e) {
      return Err(AppError('连接失败：${_netMessage(e)}'));
    }
  }

  /// 统一处理：data 可能是 Content（wait 完成），也可能是任务对象。
  Future<Result<ParsedSource>> _resolveTask(Map<String, dynamic> first) async {
    Map<String, dynamic> task = first;
    int guard = 0;
    while (true) {
      if (_isContent(task)) {
        return Ok(mapDtkContent(task));
      }
      final String state = (task['state'] ?? '').toString().toLowerCase();
      if (state == 'done') {
        final dynamic content = task['data'];
        if (content is! Map) {
          return const Err(AppError('解析结果为空'));
        }
        return Ok(mapDtkContent(Map<String, dynamic>.from(content)));
      }
      if (state == 'failed') {
        return Err(AppError(_taskError(task)));
      }
      final String? id = task['task_id']?.toString();
      if (id == null || id.isEmpty) {
        return const Err(AppError('解析服务返回格式异常'));
      }
      if (guard >= 3) {
        return const Err(AppError('解析超时，请稍后重试'));
      }
      guard += 1;
      task = await _getTask(id);
    }
  }

  bool _isContent(Map<String, dynamic> map) {
    // 任务对象只有 task_id/state/endpoint 等字段；不要把带 platform 的任务误当内容。
    return map.containsKey('content_id') || map.containsKey('media');
  }

  Future<Map<String, dynamic>> _submitParse(
    String input, {
    required bool refresh,
  }) async {
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '$_base/api/v1/parse',
        queryParameters: <String, dynamic>{
          'wait': 20,
          'lang': 'zh',
          if (refresh) 'refresh': true,
        },
        data: <String, dynamic>{'url': input, 'include_raw': true},
        options: Options(headers: _authHeaders),
      );
      return _asData(resp);
    } on DioException catch (e) {
      throw DtkException(_dioMessage(e));
    }
  }

  Future<Map<String, dynamic>> _getTask(String id) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        '$_base/api/v1/tasks/$id',
        queryParameters: <String, dynamic>{'wait': 20, 'lang': 'zh'},
        options: Options(headers: _authHeaders),
      );
      return _asData(resp);
    } on DioException catch (e) {
      throw DtkException(_dioMessage(e));
    }
  }

  Map<String, dynamic> _asData(Response<dynamic> resp) {
    final int? status = resp.statusCode;
    if (status != null && status >= 300 && status < 400) {
      throw DtkException(
        '解析服务发生重定向（HTTP $status），请使用最终地址并改用 HTTPS',
        code: 'REDIRECT',
      );
    }
    final dynamic body = resp.data;
    if (body is! Map) {
      throw DtkException('解析服务返回格式异常', code: 'BAD_RESPONSE');
    }
    final Map<String, dynamic> envelope = Map<String, dynamic>.from(body);
    if (envelope['success'] != true) {
      throw DtkException(
        _envelopeError(envelope),
        code: _envelopeCode(envelope),
      );
    }
    final dynamic data = envelope['data'];
    if (data is! Map) {
      throw DtkException('解析服务返回格式异常', code: 'BAD_RESPONSE');
    }
    return Map<String, dynamic>.from(data);
  }

  String _envelopeError(Map<String, dynamic> envelope) {
    // 网关（clipkeep-gateway）用的是 FastAPI 风格的 detail 字段，
    // 不认它就只能显示「格式异常」，等于把真实原因吞掉。
    final String? detail = _responseDetail(envelope);
    if (detail != null) {
      return detail;
    }
    final dynamic error = envelope['error'];
    if (error is Map) {
      final String? message = error['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final String? code = error['code']?.toString();
      if (code != null && code.isNotEmpty) {
        return code;
      }
    }
    return '解析服务返回错误';
  }

  /// 从各种错误响应体里捞出可读文案。
  String? _responseDetail(dynamic body) {
    if (body is! Map) {
      return null;
    }
    final String detail = (body['detail'] ?? '').toString().trim();
    if (detail.isNotEmpty) {
      return detail;
    }
    final dynamic error = body['error'];
    if (error is Map) {
      final String message = (error['message'] ?? '').toString().trim();
      if (message.isNotEmpty) {
        return message;
      }
    }
    return null;
  }

  String? _envelopeCode(Map<String, dynamic> envelope) {
    final dynamic error = envelope['error'];
    if (error is Map) {
      return error['code']?.toString();
    }
    return null;
  }

  String _taskError(Map<String, dynamic> task) {
    final dynamic error = task['error'];
    if (error is Map) {
      final String? message = error['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final String? code = error['code']?.toString();
      if (code != null && code.isNotEmpty) {
        return code;
      }
    }
    return '解析失败';
  }

  String _dioMessage(DioException e) {
    // HTTP 错误码本身没有信息量，优先用响应体里的 detail。
    final String? detail = _responseDetail(e.response?.data);
    if (detail != null) {
      return detail;
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接服务器超时';
      case DioExceptionType.receiveTimeout:
        return '等待解析结果超时';
      case DioExceptionType.sendTimeout:
        return '发送请求超时';
      case DioExceptionType.connectionError:
        return '无法连接服务器';
      default:
        return e.message ?? '网络错误';
    }
  }

  String _netMessage(Object e) {
    if (e is DioException) {
      return _dioMessage(e);
    }
    return e.toString();
  }
}
