/// 全局应用状态，持有连接配置、用户档案、人物列表并通过 shared_preferences 持久化。
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

  /// 是否使用 App 内置的 Dart 后端（手机端默认，桌面端兜底）。
  bool embedded = false;

  AppState() {
    api = ApiClient(apiBaseUrl);
  }

  /// 启动时从持久化读取连接配置（需 await 后再跑 UI）。
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

  /// 把底层连接异常转成一句可读提示，不把原始异常甩给用户。
  static String cleanConnError(Object e) {
    final s = e.toString();
    if (s.contains('Connection refused') ||
        s.contains('SocketException') ||
        s.contains('ClientException')) {
      return '无法连接后端（连接被拒绝），请确认后端服务已启动、地址端口填写正确';
    }
    return s;
  }

  /// 整包自包含：健康失败时自动拉起内置后端（仅 Windows 整包版）。
  /// 数据目录固定为 guren-data/，不可叫 data/（那是 Flutter 运行时资源目录，会冲突）。
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

  /// 手机端用内置 Dart 后端免配置；桌面端外置后端拉不起来时兜底。
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
