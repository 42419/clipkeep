/// 全局常量。
class AppConstants {
  AppConstants._();

  /// 保存到相册时的相册名。
  static const String albumName = 'ClipKeep';

  /// 设置项：下载完成后是否写入系统相册（false 则保存到 下载/ClipKeep）。
  static const String prefSaveToGallery = 'settings_save_to_gallery';

  /// 设置项：是否跟随系统壁纸动态取色。
  static const String prefDynamicColor = 'settings_dynamic_color';

  /// 抖音解析服务（DTK）地址，构建期通过 --dart-define 注入（CI Secrets），仓库不留明文。
  static const String dtkBaseUrl = String.fromEnvironment('DTK_BASE_URL');

  /// 抖音解析服务（DTK）API Key，构建期通过 --dart-define 注入（CI Secrets）。
  static const String dtkApiKey = String.fromEnvironment('DTK_API_KEY');

  /// 设置项：DTK 服务器地址（运行期可覆盖）。
  static const String prefDtkBaseUrl = 'settings_dtk_base_url';

  /// 安全存储键：DTK API Key。
  static const String secureDtkApiKey = 'settings_dtk_api_key';
}
