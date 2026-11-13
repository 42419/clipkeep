// 设备 ABI 列表：Android 用 `dart:ffi` 读真实架构，web 恒为空。
//
// 单独拆文件是为了把 `dart:ffi` 隔离在 io 实现里 —— web 平台没有这个库，
// 直接在 `update_page.dart` 里 import 会让 `flutter build web` 编译失败。
export 'abi_names_io.dart' if (dart.library.js_interop) 'abi_names_web.dart';
