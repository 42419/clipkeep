# ClipKeep 项目规约

这些规则用于保证功能持续增加时项目仍然可维护。每次改动都必须遵守。
最后更新：2026-11-06

## 目录结构

```
lib/
  api/         网络与解析：BilibiliResolver、DtkClient/dtk_mapper、DownloaderApi 路由
  pages/       页面：main_page、result_page、home/downloads/settings 三个 *_view、登录页
  stores/      provider + ChangeNotifier：DownloaderStore、AuthStore、SettingsStore、MainTabController
  utils/       下载器、格式化、图片请求头、WebView Cookie 通道
  viewmodels/  ParsedSource / MediaPart / MediaStream、DownloadTask
  components/  可复用组件（如剪贴板弹窗）
  constants/   AppConstants（相册名、prefs key、构建期 DTK 配置）
  theme/       颜色种子与圆角/间距令牌
  routes/      Provider 注入与根 Widget
test/          纯 Dart 单元测试（不依赖插件）
```

- 依赖方向：`pages -> stores -> api/utils -> viewmodels`。页面不直接发网络请求，解析/下载意图统一走 `DownloaderStore`。
- 跨层失败用 `Result<T>`（`Ok`/`Err`）返回，异常不逃出数据层；文案在 `AppError.message` 面向用户。
- 下载状态机：`DownloadStatus` + `DownloadTask`；同一任务同一时刻只允许一个运行（`_running` 串行化），进度与取消令牌按运行归属回写。

## 添加依赖

- 一律用 `flutter pub add <包名>` / `flutter pub remove <包名>`，**禁止手写版本号**；锁文件随命令更新。
- 不引入需要维护生成代码的库；当前没有 freezed/json_serializable 产物。

## 状态管理

- 使用 **provider** + `ChangeNotifier`；每个 store 暴露只读 getter 与意图方法，Widget 不改内部状态。
- Provider 只能读取**祖先** Provider；跨 Provider 传依赖用「持有实例 + `ChangeNotifierProvider.value`」。

## 下载与文件

- 多连接 Range 分片 + 视频/音频并行；服务端不支持 Range 时回退单连接。
- 暂停/失败保留 `clipkeep_*_{taskId}.m4s` 与 `.partN` 供续传；删除记录时由 `DownloaderApi.cleanup(taskId)` 清理。
- 进度：下载 0~90%，合并 90~100%；合并阶段通过 `FFmpegKit.cancel` 响应暂停。
- 成品保存：相册走 `Gal`；关闭相册走原生 `clipkeep/media_store` 的 `saveFile`。Android 10+ 用 MediaStore 写系统 `Download/ClipKeep`，Android 7~9 写公有下载目录后触发媒体扫描；复制在原生单线程执行，避免阻塞主线程。
- 删除记录**不删成品**；临时文件清理需在确认弹窗文案中说明。

## 网络与凭据

- Cookie 只发给 B 站域名（`_isBiliHost` 按 host 后缀匹配），图片按来源选头（`imageHeadersFor`）。
- DTK 地址与 Key 只通过构建期 `--dart-define`（CI Secrets）注入，不入库、不写日志、不写提交信息。
- WebView Cookie 的读取/清理由 `clipkeep/webview_cookie` 通道负责；退出登录必须同时清 CookieManager。

## 验证

- 每次改动跑 **`flutter analyze`** 与 **`flutter test test/unit_test.dart`**（纯 Dart、无插件依赖），保持零告警、测试通过；CI 同样执行这两步。
- 涉及原生代码时再跑 `android/gradlew :app:compileDebugKotlin`。
- 真机由用户安装 CI 产物验证；静态检查通过不等于功能可用。

## 文档

- 所有文档、注释、提交信息使用中文。
- README 记录构建方式、已知限制与许可证；本文件记录结构约束，避免与代码漂移。

## Git

- 首行 `<type>(<scope>): 一句话`；正文用 2 空格缩进的 `- ` 列表，说明为什么。
- 一个提交只做一件事；提交信息与文档中不得出现服务器地址、API Key、Cookie 等敏感信息。
