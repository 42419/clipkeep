/// web 没有 APK 安装包的概念，返回空列表让调用方走「没有适配当前设备的包」分支。
List<String> abiNames() => const <String>[];
