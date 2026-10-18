import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state.dart';
import 'theme.dart';
import 'screens/splash.dart';
import 'screens/settings.dart';
import 'screens/characters.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  try {
    // 最多等 3 秒载入本地配置；失败或超时则用默认配置启动，避免插件未就绪白屏。
    await state.load().timeout(const Duration(seconds: 3));
  } catch (_) {
    // 载入失败时用默认配置启动
  }
  runApp(
    ChangeNotifierProvider.value(
      value: state,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '故人',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const SplashScreen(),
      routes: {
        '/settings': (_) => const SettingsScreen(),
        '/characters': (_) => const CharacterListScreen(),
      },
    );
  }
}
