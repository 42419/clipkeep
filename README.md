# ClipKeep

Android 端视频下载工具：粘贴哔哩哔哩 / 抖音分享链接，解析后选画质保存到相册或系统下载目录（`Download/ClipKeep`）。

## 功能

- 哔哩哔哩：纯 Dart 解析（WBI 签名 + DASH），WebView 登录后解锁高清画质；支持 BV / av / b23 短链；多 P 视频按需加载当前 P 的流，串行限速避免触发风控。
- 抖音：走自部署 DTK 解析服务，支持多画质、仅音频（无独立音轨时用 FFmpeg 抽取）、精确发布时间。
- 图文/图集：可保存全部或单张图片；实况图合成为 Android Motion Photo，失败时回退为图片+视频；文字类型按单张图片处理。
- 下载：多连接 Range 分片 + 视频/音频并行，支持断点续传、备用地址回退；失败重试会刷新过期签名地址；进行中/暂停/失败任务可取消删除，重启后保留记录并清理孤儿临时文件。
- 记录：历史持久化，可重新解析；删除记录只清记录与临时文件，不删已保存的成品。
- 界面：Material 3 Expressive（`material_3_expressive`）+ 动态取色，Android-only；结果页支持复制原链接、浏览器打开、重新解析和点赞数展示。

## 环境与构建

- Flutter 3.47.9 / Dart 3.13，minSdk 24，包名 `top.yunov.clipkeep`。
- 依赖安装与检查：

  ```bash
  flutter pub get
  flutter analyze
  ```

- 打测试包（arm64-v8a）：

  ```bash
  flutter build apk --release --split-per-abi \
    --dart-define=DTK_BASE_URL=<你的 DTK 地址> \
    --dart-define=DTK_API_KEY=<你的 Key>
  ```

未注入 DTK 配置时，抖音解析会提示「未配置解析服务」，B 站功能不受影响。CI 从 GitHub Actions Secrets 读取这两项。

> 安全提示：`--dart-define` 的值会编进 APK。公开分发等同于公开 Key，请在 DTK 服务端限流、按设备签发短期令牌，不要依赖客户端保密。

## 目录

```
lib/
  api/         BilibiliResolver（WBI）、DtkClient + dtk_mapper、DownloaderApi 路由
  pages/       main_page、result_page、home/downloads/settings 三个 view、WebView 登录页
  stores/      DownloaderStore（解析 + 任务）、AuthStore、SettingsStore、MainTabController
  utils/       media_downloader（分片/续传/FFmpeg）、format、image_headers、webview_cookies
  viewmodels/  ParsedSource / MediaPart / MediaStream、DownloadTask
  theme/ constants/ components/ routes/
```

开发约定见 `docs/CONVENTIONS.md`。

## 已知限制

- 多 P 视频只支持哔哩哔哩；切换分 P 时才会请求新的 playurl，并做串行限速/412 冷却重试。
- 进行中任务会持久化，但签名地址不持久化：重启后继续会重新拉流并从零下载（记录和未完成状态保留）。
- 无前台服务，长时间后台/熄屏下载仍可能被系统挂起。
- 图文/图集：支持保存图片；实况图优先合成 Android Motion Photo，合成失败回退为图片 + 独立 mp4；文字类型本质是单张图片，不单独提供正文下载。
- Motion Photo 合成依赖 `flutter_live_motion`，极旧 ROM 或第三方相册可能不识别动态效果。
- 抖音解析依赖自部署服务，不是内置能力。
- 暂停只保留临时文件供续传；签名地址过期后请用「重试」刷新，而不是「继续」。

## 许可证

ClipKeep 以 **GPL-3.0-or-later** 发布，完整文本见 [LICENSE](LICENSE)，版权与授权声明见 [NOTICE](NOTICE)。分发 APK 时需随附完整对应源码并保留版权与许可声明。

第三方来源与许可：

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：GPL-3.0-or-later，`BilibiliResolver` 的接口调用与 WBI 签名参考其实现并改写。
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)：CC-BY-NC 4.0，WBI mixinKey 置换表与接口文档来源；注意其**非商业**限制。
- [Douyin_TikTok_Download_API](https://github.com/Evil0ctal/Douyin_TikTok_Download_API)：Apache-2.0，仅通过 REST 调用，未内嵌其代码。
- [FFmpegKit for Flutter](https://pub.dev/packages/ffmpeg_kit_flutter_new)：插件 LGPL-3.0，所用 `ffmpeg_kit_flutter_new` 为 **Full GPL** 变体（含 x264/x265 等 GPL 组件），因此整个应用按 GPL-3.0 分发。
- [flutter_live_motion](https://pub.dev/packages/flutter_live_motion)：MIT，用于生成 Android Motion Photo。

本应用与哔哩哔哩、抖音无隶属关系，仅供学习研究；请仅下载你有权保存的内容。
