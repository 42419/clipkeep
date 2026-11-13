import 'dart:ffi' show Abi;

/// 当前设备优先尝试的 ABI，顺序与 `build.gradle` 的 abiFilters 对齐。
List<String> abiNames() {
  final Abi abi = Abi.current();
  if (abi == Abi.androidArm64) {
    return const <String>['arm64-v8a'];
  }
  if (abi == Abi.androidArm) {
    return const <String>['armeabi-v7a', 'arm64-v8a'];
  }
  if (abi == Abi.androidX64) {
    return const <String>['x86_64'];
  }
  return const <String>['arm64-v8a'];
}
