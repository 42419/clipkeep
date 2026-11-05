import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 哔哩哔哩账号资料。
class BiliProfile {
  const BiliProfile({
    required this.uname,
    required this.face,
    required this.mid,
    required this.vip,
  });

  final String uname;
  final String face;
  final int mid;
  final bool vip;
}

/// 登录态：保存 Cookie（仅本机安全存储），并校验账号资料。
class AuthStore extends ChangeNotifier {
  AuthStore({FlutterSecureStorage? storage, Dio? dio})
    : _storage = storage ?? const FlutterSecureStorage(),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ),
          );

  static const String _kCookie = 'bili_cookie';
  static const String _kUname = 'bili_uname';
  static const String _kFace = 'bili_face';
  static const String _kMid = 'bili_mid';
  static const String _kVip = 'bili_vip';

  static const List<String> _cookieKeys = <String>[
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
  ];

  final FlutterSecureStorage _storage;
  final Dio _dio;

  String? _cookie;
  String? _uname;
  String? _face;
  int? _mid;
  bool _vip = false;
  bool _ready = false;

  bool get ready => _ready;
  String? get cookie => _cookie;
  String? get uname => _uname;
  String? get face => _face;
  int? get mid => _mid;
  bool get vip => _vip;
  bool get isLoggedIn =>
      _cookie != null && _cookie!.contains('SESSDATA=');

  Future<void> load() async {
    try {
      _cookie = await _storage.read(key: _kCookie);
      _uname = await _storage.read(key: _kUname);
      _face = await _storage.read(key: _kFace);
      final String? midText = await _storage.read(key: _kMid);
      _mid = int.tryParse(midText ?? '');
      _vip = (await _storage.read(key: _kVip)) == 'true';
    } catch (_) {
      // 读取失败按未登录处理。
    }
    _ready = true;
    notifyListeners();
    if (isLoggedIn) {
      unawaited(refreshProfile(silent: true));
    }
  }

  /// 用 WebView 拿到的 Cookie 登录；会先用 nav 接口校验。
  Future<bool> loginWithCookie(String rawCookie) async {
    final String cookie = sanitizeCookie(rawCookie);
    final BiliProfile? profile = await _fetchProfile(cookie);
    if (profile == null) {
      return false;
    }
    _cookie = cookie;
    _uname = profile.uname;
    _face = profile.face;
    _mid = profile.mid;
    _vip = profile.vip;
    await _persist();
    notifyListeners();
    return true;
  }

  /// 静默刷新资料；失效时（非静默）退出登录。
  Future<bool> refreshProfile({bool silent = false}) async {
    final String? cookie = _cookie;
    if (cookie == null) {
      return false;
    }
    final BiliProfile? profile = await _fetchProfile(cookie);
    if (profile == null) {
      if (!silent) {
        await logout();
      }
      return false;
    }
    _uname = profile.uname;
    _face = profile.face;
    _mid = profile.mid;
    _vip = profile.vip;
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    _cookie = null;
    _uname = null;
    _face = null;
    _mid = null;
    _vip = false;
    try {
      await _storage.delete(key: _kCookie);
      await _storage.delete(key: _kUname);
      await _storage.delete(key: _kFace);
      await _storage.delete(key: _kMid);
      await _storage.delete(key: _kVip);
    } catch (_) {
      // 清理失败忽略。
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _storage.write(key: _kCookie, value: _cookie);
      await _storage.write(key: _kUname, value: _uname);
      await _storage.write(key: _kFace, value: _face);
      await _storage.write(key: _kMid, value: _mid?.toString());
      await _storage.write(key: _kVip, value: _vip.toString());
    } catch (_) {
      // 写入失败不影响当前会话。
    }
  }

  Future<BiliProfile?> _fetchProfile(String cookie) async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        'https://api.bilibili.com/x/web-interface/nav',
        options: Options(
          headers: <String, String>{
            'cookie': cookie,
            'user-agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
            'referer': 'https://www.bilibili.com/',
          },
        ),
      );
      final dynamic body = res.data;
      if (body is Map && body['code'] == 0) {
        final dynamic data = body['data'];
        if (data is Map && data['isLogin'] == true) {
          return BiliProfile(
            uname: (data['uname'] ?? '').toString(),
            face: (data['face'] ?? '').toString(),
            mid: (data['mid'] as num?)?.toInt() ?? 0,
            vip: (data['vipStatus'] as num?) == 1,
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 只保留登录必需的 Cookie 项，拼成 HTTP Cookie 头。
  static String sanitizeCookie(String raw) {
    final List<String> kept = <String>[];
    for (final String part in raw.split(';')) {
      final String item = part.trim();
      final int eq = item.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final String key = item.substring(0, eq).trim();
      if (_cookieKeys.contains(key)) {
        kept.add(item);
      }
    }
    return kept.isEmpty ? raw.trim() : kept.join('; ');
  }
}
