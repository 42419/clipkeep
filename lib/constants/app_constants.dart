/// 全局常量。
class AppConstants {
  AppConstants._();

  /// 保存到相册时的相册名。
  static const String albumName = 'ClipKeep';

  /// 设置项：下载完成后是否写入系统相册（false 则保存到系统 Download/ClipKeep）。
  static const String prefSaveToGallery = 'settings_save_to_gallery';

  /// 设置项：是否跟随系统壁纸动态取色。
  static const String prefDynamicColor = 'settings_dynamic_color';

  /// 设置项：回到前台时是否自动检测剪贴板链接。
  static const String prefClipboardAuto = 'clipboard_auto';

  /// 设置项：同时下载的任务数（1~4）。
  static const String prefMaxConcurrent = 'settings_max_concurrent';

  /// 抖音解析服务（DTK）地址，仅作开发期 --dart-define 默认值；正式构建留空，由用户在设置页填写。
  static const String dtkBaseUrl = String.fromEnvironment('DTK_BASE_URL');

  /// 抖音解析服务（DTK）API Key，仅作开发期 --dart-define 默认值；正式构建不注入。
  static const String dtkApiKey = String.fromEnvironment('DTK_API_KEY');

  /// 设置项：DTK 服务器地址（运行期可覆盖）。
  static const String prefDtkBaseUrl = 'settings_dtk_base_url';

  /// 安全存储键：DTK API Key。
  static const String secureDtkApiKey = 'settings_dtk_api_key';

  /// GitHub 仓库（owner/name），用于检查更新。
  static const String githubRepo = '42419/clipkeep';

  /// 更新清单（update.json）地址。
  ///
  /// 为空时走 GitHub Releases：取 latest release 里的 update.json 资产。
  /// 将来换国内源只需在构建期注入 `UPDATE_MANIFEST_URL` 或改这里的默认值。
  static const String updateManifestUrl = String.fromEnvironment(
    'UPDATE_MANIFEST_URL',
  );
}
