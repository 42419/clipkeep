/// 全局常量。
class AppConstants {
  AppConstants._();

  /// 保存到相册时的相册名。
  static const String albumName = 'ClipKeep';

  /// 设置项：下载完成后是否写入系统相册（false 则保存到 下载/ClipKeep）。
  static const String prefSaveToGallery = 'settings_save_to_gallery';

  /// 设置项：是否跟随系统壁纸动态取色。
  static const String prefDynamicColor = 'settings_dynamic_color';
}
