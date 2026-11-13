# ClipKeep

Android 端视频下载工具：粘贴抖音分享链接，解析后选画质保存到相册或系统下载目录（`Download/ClipKeep`）。

## 功能

- 抖音：走自部署 DTK 解析服务，支持多画质、精确发布时间。
- 图文/图集：可保存全部或单张图片；实况图默认合成为 Android Motion Photo，也可选「图片+视频」分别保存；文字类型按单张图片处理。首页右上角提供手动合成入口，可自选本地图片与视频。
- 下载：多连接 Range 分片，支持断点续传、备用地址回退；失败按退避自动重试并刷新签名地址，网络恢复后也会重试网络失败的记录；同时下载数可设（1~3），其余排队；启动前检查剩余空间。
- 文件：可读文件名（`日期-类型-作者-标题-清晰度-内容ID`），支持在下载记录里打开或分享成品。
- 通知：下载前台服务 + 进度通知 + 完成提醒，熄屏/切后台时任务不会被立即挂起。
- 记录：进行中/暂停/排队/失败任务持久化，重启后保留（未完成转为暂停）；可取消删除、重新解析；删除记录只清记录与临时文件，不删已保存的成品。
- 界面：原生 Material 3（`ColorScheme.fromSeed` + 动态取色，跟随系统深色），Android-only；结果页支持复制原链接、浏览器打开、重新解析和点赞数展示。
- 设置：解析服务凭证（自填地址 / Key，自动保存本机）、保存位置、同时下载、剪贴板检测、动态取色、缓存清理、完整更新日志。
- 更新：CNB 主源、GitHub 保底；`update.json` 同时写入两平台直链，下载失败自动切换；按设备 ABI 选安装包、校验 SHA-256 后经 FileProvider 调起系统安装。

## 环境与构建

- Flutter 3.47.9 / Dart 3.13，minSdk 24，包名 `top.yunov.clipkeep`。
- 依赖安装与检查：

  ```bash
  flutter pub get
  flutter analyze
  ```

- 打测试包（arm64-v8a）：

  ```bash
  flutter build apk --release --split-per-abi
  ```

正式构建**不内置** DTK 地址与 Key。首次解析前，在设置页「解析服务」填写自建 DTK 地址与仅含 `douyin:read` 权限的 API Key；凭证自动保存在本机安全存储，除非手动修改或清除，否则一直保留。

发布流水线会把 Release 与附件同步到 CNB；需在 GitHub Actions 配置 `CNB_TOKEN`（repo-release:rw）。同步是独立 workflow，失败不影响 GitHub 发布。

> 开发调试可用 `--dart-define=DTK_BASE_URL=... --dart-define=DTK_API_KEY=...` 提供默认值，但公开分发的 APK 不要使用，避免 Key 随包泄露。

## 网页版

同一份代码也能产出 web 页面：

```bash
flutter build web --release    # 产物在 build/web
```

web 端把下载交给浏览器，不落盘、不留队列：

| 能力 | Android | Web |
|---|---|---|
| 鉴权 | 设置页填解析服务地址与 Key | 输入访问口令 |
| 下载 | 落盘、写相册、断点续传 | 交给浏览器下载 |
| 下载队列 / 历史 | 有 | 无（刷新即清空） |
| 实况图合成、动态取色、检查更新、剪贴板自动检测 | 有 | 隐藏 |
| 图集保存 | 逐张落盘 | 逐张交给浏览器 |

产物是纯静态文件，放到任意静态服务器即可；接口需与页面同源。

## 目录

```
lib/
  api/         DtkClient + dtk_mapper、DownloaderApi、GatewaySession、UpdateService、Changelog 解析
  pages/       main_page、result_page、update_page、login/、home/downloads/settings 三个 view
  platform/    abi_names（dart:ffi 条件导入，web 返回空）
  stores/      DownloaderStore（解析 + 任务）、SettingsStore、MainTabController
  utils/       media_downloader（门面）、media_downloader_io / _web、format、image_headers
  viewmodels/  ParsedSource / MediaPart / MediaStream、DownloadTask
  theme/ constants/ components/ routes/
web/           Flutter web 入口与 manifest
scripts/       gen_update_manifest.py（CI 生成 update.json 与 Release 说明）
test/          unit_test.dart（纯 Dart 单元测试）
```

开发约定见 `AGENTS.md`。

## 已知限制

- 仅支持抖音；非抖音链接会直接提示不支持。
- 进行中任务会持久化，但签名地址不持久化：重启后继续会重新拉流并从零下载（记录和未完成状态保留）；同一画质且编码/带宽一致的手动重试会复用临时分片；档位或编码变化、重启后均从零下载。
- 下载期间有前台服务与通知，但强制停止应用或被系统清理后仍会中断；重启后任务保留为暂停，需手动继续。
- 网络失败会自动重试 2 次（2s / 5s）；长时间断网或签名过期超过重试窗口时，仍需手动「重试」。
- 图文/图集：支持保存图片；实况图默认合成 Android Motion Photo，也可改用「图片+视频」分别保存；文字类型本质是单张图片，不单独提供正文下载。
- Motion Photo 依赖相册支持：部分机型或旧系统只显示静态图，此时请用「图片+视频」分开保存，或从首页右上角手动合成后分享到支持的应用。
- 抖音解析依赖自部署服务，不是内置能力。
- 更新源为 CNB 主源 + GitHub 保底；CNB 不可达时自动回退。更新日志与更新说明已打进 APK，离线可看。
- 暂停只保留临时文件供续传；签名地址过期后请用「重试」刷新，而不是「继续」。
- Android-only，没有 Web / iOS 版本。

## 许可证

ClipKeep 以 **MIT** 发布，完整文本见 [LICENSE](LICENSE)，版权与第三方声明见 [NOTICE](NOTICE)。

第三方来源与许可：

- 自部署 DTK 解析服务（Apache-2.0）：仅通过 REST 调用，未内嵌其代码。
- [flutter_live_motion](https://pub.dev/packages/flutter_live_motion)：MIT，用于生成 Android Motion Photo。
- 其余 pub.dev 依赖遵循各自许可证。

本应用与抖音无隶属关系，仅供学习研究；请仅下载你有权保存的内容。
