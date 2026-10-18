/// 全局应用状态（provider + ChangeNotifier）。
///
/// 持有后端地址、LLM 配置、用户档案、人物列表、连接健康状态，
/// 并通过 shared_preferences 持久化连接配置。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'backend/backend.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  late ApiClient api;
  String apiBaseUrl = 'http://127.0.0.1:8000';
  LLMConfig llm = const LLMConfig();
  UserProfile user = const UserProfile();
  List<CharacterIndex> characters = [];
  bool connected = false;
  String? error;

  /// 是否跑的是 App 内置的 Dart 后端（手机端默认，桌面端兜底）。
  bool embedded = false;

  AppState() {
    api = ApiClient(apiBaseUrl);
  }

  /// 启动时从持久化读取连接配置。必须 await 后再跑 UI。
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    apiBaseUrl = p.getString('apiBaseUrl') ?? 'http://127.0.0.1:8000';
    llm = LLMConfig(
      apiKey: p.getString('llmKey') ?? '',
      baseUrl: p.getString('llmBase') ?? '',
      model: p.getString('llmModel') ?? '',
    );
    api = ApiClient(apiBaseUrl);
    notifyListeners();
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('apiBaseUrl', apiBaseUrl);
    await p.setString('llmKey', llm.apiKey);
    await p.setString('llmBase', llm.baseUrl);
    await p.setString('llmModel', llm.model);
  }

  /// 写入新的连接配置并立即生效。
  void applyConnection(String url, LLMConfig cfg) {
    apiBaseUrl = url.trim();
    llm = cfg;
    api = ApiClient(apiBaseUrl);
    _persist();
    notifyListeners();
  }

  Future<bool> checkHealth() async {
    try {
      await api.getHealth();
      connected = true;
      error = null;
    } catch (e) {
      connected = false;
      error = cleanConnError(e);
    }
    notifyListeners();
    return connected;
  }

  /// 把底层连接异常转成一句人话，别把 SocketException/ClientException 整坨甩给用户。
  static String cleanConnError(Object e) {
    final s = e.toString();
    if (s.contains('Connection refused') ||
        s.contains('SocketException') ||
        s.contains('ClientException')) {
      return '无法连接后端（连接被拒绝），请确认后端服务已启动、地址端口填写正确';
    }
    return s;
  }

  /// 整包自包含：健康检查失败时，自动拉起打包内置的后端（仅 Windows 整包版有）。
  ///
  /// 布局约定：<包目录>/server/guren-server.exe（PyInstaller 冻结的单文件服务），
  /// 数据落在 <包目录>/guren-data/。注意不能叫 data/——那是 Flutter Windows
  /// 运行时资源目录（app.so/icudtl.dat/flutter_assets），撞名会互相污染。  /// 服务端带父进程看门狗，App 退出时服务自杀，不留孤儿。
  /// 开发模式（flutter run）没有 server/ 目录，直接返回 false 走原设置页流程。
  Future<bool> startBundledServer() async {
    if (!Platform.isWindows) return false;
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      final exe = File('${dir.path}${Platform.pathSeparator}server'
          '${Platform.pathSeparator}guren-server.exe');
      if (!exe.existsSync()) return false;
      final dataDir = Directory('${dir.path}${Platform.pathSeparator}guren-data');
      if (!dataDir.existsSync()) dataDir.createSync(recursive: true);
      await Process.start(
        exe.path,
        const [],
        mode: ProcessStartMode.detached,
        environment: {
          'GUREN_PORT': '8000',
          'GUREN_DATA': dataDir.path,
          'GUREN_PARENT_PID': '$pid',
        },
      );
      // onefile 首次要解压再起服务，最多等 30s
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await checkHealth()) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 手机端没有 Python，用 App 内置的 Dart 后端：起一个只监听 127.0.0.1 的服务，
  /// 装完即用，不用连电脑、不用填地址。桌面端在外置后端拉不起来时也走这条路兜底。
  Future<bool> startEmbeddedServer() async {
    try {
      final url = await EmbeddedBackend().start();
      apiBaseUrl = url;
      api = ApiClient(url);
      embedded = true;
      notifyListeners();
      return await checkHealth();
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshCharacters() async {
    characters = await api.listCharacters();
    notifyListeners();
  }

  Future<void> loadUser() async {
    try {
      user = await api.getUser();
      notifyListeners();
    } catch (_) {
      // 后端未配置用户档案时容忍失败
    }
  }
}
