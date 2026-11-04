import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

// C signatures of crates/bdl-ffi (see the bdl fork):
//   char* bdl_parse(const char* request_json);
//   void  bdl_free_string(char* value);
typedef _ParseNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _ParseDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);

/// Thin, synchronous bindings to `libbdl_ffi.so`.
///
/// Never call this from the UI. Use [BdlService], which runs it on a background
/// isolate. One instance is bound to the isolate that opened it.
class BdlFfi {
  BdlFfi._(this._lib)
      : _parse = _lib.lookupFunction<_ParseNative, _ParseDart>('bdl_parse'),
        _free = _lib.lookupFunction<_FreeNative, _FreeDart>('bdl_free_string');

  factory BdlFfi.open() => BdlFfi._(_openLibrary());

  // Held so the loaded library (and its function pointers) stays alive.
  // ignore: unused_field
  final ffi.DynamicLibrary _lib;
  final _ParseDart _parse;
  final _FreeDart _free;

  static ffi.DynamicLibrary _openLibrary() {
    // Android packages the library as jniLibs/<abi>/libbdl_ffi.so.
    return ffi.DynamicLibrary.open('libbdl_ffi.so');
  }

  /// Resolve a Bilibili input and return the JSON envelope:
  /// `{ "ok": true, "data": {...} }` or `{ "ok": false, "error": "..." }`.
  Map<String, dynamic> parse(Map<String, dynamic> request) {
    final requestPtr = jsonEncode(request).toNativeUtf8();
    try {
      final resultPtr = _parse(requestPtr);
      if (resultPtr == ffi.nullptr) {
        return const {'ok': false, 'error': 'bdl_parse returned a null pointer'};
      }
      try {
        return jsonDecode(resultPtr.toDartString()) as Map<String, dynamic>;
      } finally {
        _free(resultPtr);
      }
    } finally {
      malloc.free(requestPtr);
    }
  }
}
