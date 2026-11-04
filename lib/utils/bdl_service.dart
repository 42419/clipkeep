import 'dart:isolate';

import 'bdl_ffi.dart';

/// Async facade over [BdlFfi]. Every call runs on a background isolate because
/// `bdl_parse` blocks on network and CPU.
class BdlService {
  const BdlService();

  Future<BdlParseResult> parse({
    required String input,
    required String stateDir,
    bool withStreams = true,
    String? cookie,
    int maxOperations = 50,
    int maxHttpRequests = 100,
    double intervalSeconds = 0.5,
  }) async {
    final request = <String, dynamic>{
      'input': input,
      'with_streams': withStreams,
      'cookie': cookie,
      'state_dir': stateDir,
      'max_operations': maxOperations,
      'max_http_requests': maxHttpRequests,
      'interval_seconds': intervalSeconds,
    };
    final envelope = await Isolate.run(() => _parseInIsolate(request));
    final ok = envelope['ok'] == true;
    return BdlParseResult(
      ok: ok,
      data: ok ? (envelope['data'] as Map?)?.cast<String, dynamic>() : null,
      error: ok ? null : envelope['error'] as String?,
    );
  }
}

Map<String, dynamic> _parseInIsolate(Map<String, dynamic> request) {
  return BdlFfi.open().parse(request);
}

/// Outcome of a resolve request.
class BdlParseResult {
  const BdlParseResult({required this.ok, this.data, this.error});
  final bool ok;
  final Map<String, dynamic>? data;
  final String? error;
}
