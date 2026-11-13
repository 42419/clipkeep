// 下载实现按平台分流：
//
// - `media_downloader_io.dart`：Android / 桌面，落盘 + 相册 + 断点续传
// - `media_downloader_web.dart`：web，只负责把 `/dl?u=…&n=…` 交给浏览器
//
// 两个实现提供完全相同的 `MediaDownloader` 接口，调用方（DownloaderApi / Store）
// 不需要感知平台。
export 'media_downloader_io.dart'
    if (dart.library.js_interop) 'media_downloader_web.dart';
