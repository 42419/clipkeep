import 'package:dio/dio.dart';

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

  bool get isConfigured =>
      normalizedBase.isNotEmpty && apiKey.trim().isNotEmpty;
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
    } on DtkUnsupported catch (e) {
      return Err(AppError(e.message, cause: e));
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
    } on DtkUnsupported catch (e) {
      return Err(AppError(e.message, cause: e));
    } on DtkException catch (e) {
      return Err(AppError(e.message, cause: e));
    } catch (e) {
      return Err(AppError('刷新下载地址失败：${_netMessage(e)}', cause: e));
    }
  }

  /// 测试连通性与 Key 有效性（用一个必然被拒的 host，不消耗身份）。
  Future<Result<String>> check() async {
    if (!config.isConfigured) {
      return const Err(AppError('请先填写服务器地址和 API Key'));
    }
    try {
      final Response<dynamic> health = await _dio.get<dynamic>(
        '$_base/healthz',
      );
      if (health.statusCode != 200) {
        return Err(AppError('无法连接服务器（HTTP ${health.statusCode}）'));
      }
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '$_base/api/v1/parse',
        queryParameters: <String, dynamic>{'wait': 0, 'lang': 'zh'},
        data: <String, dynamic>{'url': 'https://example.com/'},
        options: Options(headers: _authHeaders),
      );
      if (resp.statusCode == 401) {
        return const Err(AppError('API Key 无效或缺失'));
      }
      final dynamic body = resp.data;
      if (body is Map) {
        final Map<String, dynamic> envelope = Map<String, dynamic>.from(body);
        if (envelope['success'] == true ||
            _envelopeCode(envelope) == 'INVALID_URL') {
          return const Ok('连接正常');
        }
        return Err(AppError(_envelopeError(envelope)));
      }
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
    return map.containsKey('content_id') ||
        map.containsKey('media') ||
        map.containsKey('platform');
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
        data: <String, dynamic>{'url': input},
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
