/// 启动页：检查后端健康，按连接状态路由到设置页或人物列表。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import 'settings.dart';
import 'characters.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _status = '正在连接后端…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = context.read<AppState>();
    var ok = await s.checkHealth();
    // 整包自包含：没连上就自动拉起内置后端，用户无需自己装环境起服务
    if (!ok && mounted) {
      setState(() => _status = '正在启动内置后端…');
      // 先试整包内置的 Python 后端（桌面端，带 OCR）；没有就起 App 内置的 Dart 后端
      ok = await s.startBundledServer();
      if (!ok) ok = await s.startEmbeddedServer();
    }
    if (!mounted) return;
    if (ok) {
      await s.refreshCharacters();
      await s.loadUser();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const CharacterListScreen()),
      );
    } else {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('故人', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(_status, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
