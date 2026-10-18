/// 内嵌后端的启动门面。
///
/// 手机端装不了 Python，所以把后端用 Dart 复刻了一份跑在 App 进程里，
/// 只监听 127.0.0.1 —— 手机不用配任何地址、不用连电脑，装完即用。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'server.dart';

class EmbeddedBackend {
  static EmbeddedServer? _server;

  static bool get running => _server != null;

  /// 启动内置后端，返回它的 baseUrl（形如 http://127.0.0.1:54321）。
  Future<String> start() async {
    if (_server != null) return _server!.baseUrl;
    final s = EmbeddedServer(await dataDir());
    await s.start();
    _server = s;
    return s.baseUrl;
  }

  /// 数据目录：各平台的应用私有目录，卸载才清。
  static Future<String> dataDir() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return '${d.path}${Platform.pathSeparator}guren-data';
    } catch (_) {
      // 插件没就绪时退回当前目录，保证桌面端调试也不至于崩
      return '${Directory.current.path}${Platform.pathSeparator}guren-data';
    }
  }
}
