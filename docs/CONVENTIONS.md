# ClipKeep 项目规约

这些规则用于保证功能不断增加时项目仍然可维护。每次改动都必须遵守。

## 添加依赖

- 一律用 `flutter pub add <包名>`（或 `flutter pub add --dev <包名>`）添加依赖，**禁止手写 `pubspec.yaml` 里的版本号**。`flutter pub add` 会自动解析版本并更新 `pubspec.lock`。

## 目录结构（按功能优先 + 分层）

```
lib/
  main.dart
  app/         app.dart、router.dart、theme.dart、providers.dart
  core/        result.dart、logger、constants、extensions
  ffi/         bdl_ffi.dart（绑定）、bdl_service.dart（异步/isolate）
  features/<名称>/
    domain/    entities/、repositories/（接口）、usecases/
    data/      dto/、datasources/、repositories/（实现）
    presentation/  pages/、widgets/、controllers/（ChangeNotifier）
  shared/      widgets/、utils/
tool/          fetch_ffi.ps1 / fetch_ffi.sh
```

## 依赖方向

- `presentation -> domain <- data`；`domain` 不得 import Flutter、dart:io 或 FFI。
- FFI 只允许出现在 `lib/ffi/` 与 `features/*/data/datasources/`，widget 与 controller 不得直接调用。
- 所有跨层对象都是不可变模型；DTO 与 entity 之间显式映射。

## 状态管理

- 使用 **provider**（package:provider）+ `ChangeNotifier`。
- 每个功能页面对应一个 controller，通过 `ChangeNotifierProvider` 暴露。
- Widget 不得直接改 controller 状态，只能调用 controller 的意图方法。

## 错误处理

- data/domain 返回 `Result<T>`（`Ok`/`Err`），异常不得抛到 UI。
- controller 负责把 `Err` 转成可见状态与用户可读文案。

## 并发

- 原生与网络工作全部离开 UI 线程。FFI 调用统一走 `BdlService`（内部用 `Isolate.run`）。

## 生成代码

- `.g.dart` / `.freezed.dart` 提交入库，CI 不必运行 build_runner。需要重新生成时执行 `dart run build_runner build --delete-conflicting-outputs`。

## 文档

- 所有 markdown 文档一律使用中文。

## Android

- minSdk = 24（`ffmpeg_kit_flutter_new` 的硬性要求）。
- 原生 FFI 库 `libbdl_ffi.so` 不入库，由 `tool/fetch_ffi.*` 从 bdl 的 `ffi` release 下载并校验。
- ABI：arm64-v8a、armeabi-v7a、x86_64。
- 签名：keystore 与 `key.properties` 不入库；本机放 `android/key.properties`，CI 从 GitHub Secrets 还原。

## 新增一个功能

1. 建 `features/<名称>/{domain,data,presentation}`。
2. 定义 domain entity、repository 接口与 usecase。
3. 在 `data` 里实现 DTO/datasource/repository。
4. 加 `ChangeNotifier` controller、页面与路由。
5. 为 domain/usecase 补单元测试；跑 `flutter analyze` 与 `flutter test`。
