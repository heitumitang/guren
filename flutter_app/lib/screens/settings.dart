/// 设置页：后端地址 + LLM 配置 + 用户档案 + 连接测试。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'characters.dart';

/// 常见模型服务商预设（OpenAI 兼容接口）。点一下自动填 Base URL 和模型名。
class _ModelPreset {
  final String name;
  final String baseUrl;
  final String model;
  const _ModelPreset(this.name, this.baseUrl, this.model);
}

const _presets = [
  _ModelPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  _ModelPreset('通义千问 Qwen', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
  _ModelPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  _ModelPreset('Kimi（月之暗面）', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
  _ModelPreset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash'),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtl = TextEditingController();
  final _keyCtl = TextEditingController();
  final _baseCtl = TextEditingController();
  final _modelCtl = TextEditingController();

  final _nameCtl = TextEditingController();
  final _genderCtl = TextEditingController();
  final _birthdayCtl = TextEditingController();
  final _mbtiCtl = TextEditingController();
  final _occCtl = TextEditingController();
  final _hobbiesCtl = TextEditingController();
  final _bioCtl = TextEditingController();

  bool _testing = false;
  String? _testMsg;
  bool? _testOk;

  bool _userLoaded = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _urlCtl.text = s.apiBaseUrl;
    _keyCtl.text = s.llm.apiKey;
    _baseCtl.text = s.llm.baseUrl;
    _modelCtl.text = s.llm.model;
  }

  @override
  void dispose() {
    for (final c in [
      _urlCtl,
      _keyCtl,
      _baseCtl,
      _modelCtl,
      _nameCtl,
      _genderCtl,
      _birthdayCtl,
      _mbtiCtl,
      _occCtl,
      _hobbiesCtl,
      _bioCtl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  LLMConfig _readLlm() => LLMConfig(
        apiKey: _keyCtl.text.trim(),
        baseUrl: _baseCtl.text.trim(),
        model: _modelCtl.text.trim(),
      );

  /// 手机端跑的是 App 内置后端，地址栏不展示，直接用运行中的那个地址。
  String _backendUrl() {
    final s = context.read<AppState>();
    if (s.embedded) return s.apiBaseUrl;
    return _urlCtl.text.trim().isEmpty ? s.apiBaseUrl : _urlCtl.text.trim();
  }

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMsg = null;
      _testOk = null;
    });
    final s = context.read<AppState>();
    s.applyConnection(_backendUrl(), _readLlm());
    try {
      final r = await s.api.testConfig(s.llm);
      setState(() {
        _testOk = r.ok;
        _testMsg = r.ok
            ? '连接成功，模型回执：「${r.reply ?? ''}」'
            : '连接失败：${r.error ?? '未知错误'}';
      });
    } on Exception catch (e) {
      setState(() {
        _testOk = false;
        _testMsg = AppState.cleanConnError(e).replaceFirst('ApiException', '');
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _loadUser() async {
    final s = context.read<AppState>();
    await s.loadUser();
    _nameCtl.text = s.user.name;
    _genderCtl.text = s.user.gender;
    _birthdayCtl.text = s.user.birthday;
    _mbtiCtl.text = s.user.mbti;
    _occCtl.text = s.user.occupation;
    _hobbiesCtl.text = s.user.hobbies;
    _bioCtl.text = s.user.bio;
    setState(() => _userLoaded = true);
  }

  Future<void> _saveUser() async {
    final s = context.read<AppState>();
    final u = s.user.copyWith(
      name: _nameCtl.text.trim(),
      gender: _genderCtl.text.trim(),
      birthday: _birthdayCtl.text.trim(),
      mbti: _mbtiCtl.text.trim(),
      occupation: _occCtl.text.trim(),
      hobbies: _hobbiesCtl.text.trim(),
      bio: _bioCtl.text.trim(),
    );
    try {
      await s.api.putUser(u);
      s.user = u;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存用户档案')));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  Future<void> _enter() async {
    final s = context.read<AppState>();
    s.applyConnection(_backendUrl(), _readLlm());
    final ok = await s.checkHealth();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法连接后端：${s.error}')));
      return;
    }
    await s.refreshCharacters();
    await s.loadUser();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const CharacterListScreen()),
    );
  }

  /// 清除本机保存的所有配置（API key、地址、模型、用户档案等）。
  Future<void> _clearConfig() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本地配置？'),
        content: const Text('将清空 API Key、后端地址、模型名等本机设置（人物数据不受影响）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除', style: TextStyle(color: kCinnabar)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final p = await SharedPreferences.getInstance();
    await p.clear();
    if (!mounted) return;
    final s = context.read<AppState>();
    s.applyConnection(
        s.embedded ? s.apiBaseUrl : 'http://127.0.0.1:8000', const LLMConfig());
    _urlCtl.text = s.apiBaseUrl;
    _keyCtl.text = '';
    _baseCtl.text = '';
    _modelCtl.text = '';
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清除本地配置')));
  }

  /// 手机端内置后端状态；只有真跑起来才显示「已启用」，避免假成功误导。
  Widget _buildEmbeddedStatus() {
    final s = context.watch<AppState>();
    final ok = s.embedded && s.connected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline,
              size: 16, color: ok ? kWechatGreen : kCinnabar),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              ok ? '已启用手机内置后端，装完即用，无需配置地址'
                  : '手机内置后端未启动（可能是权限或存储被限制）',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (!ok)
            TextButton(
              onPressed: _retryEmbedded,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }

  Future<void> _retryEmbedded() async {
    final s = context.read<AppState>();
    final ok = await s.startEmbeddedServer();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '内置后端已启动' : '内置后端启动失败，请重启应用再试'),
    ));
    if (!ok) return;
    await s.refreshCharacters();
    await s.loadUser();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接与设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('后端连接'),
          if (_isMobile) _buildEmbeddedStatus()
          else ...[
            TextField(
              controller: _urlCtl,
              decoration: const InputDecoration(
                labelText: '后端地址',
                hintText: 'http://127.0.0.1:8000',
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '电脑端保持默认即可。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _sectionTitle('大模型配置（API key 只存在本机）'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _presets.map((p) => ActionChip(
              label: Text(p.name, style: const TextStyle(fontSize: 13)),
              onPressed: () {
                setState(() {
                  _baseCtl.text = p.baseUrl;
                  _modelCtl.text = p.model;
                });
              },
            )).toList(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtl,
            decoration: const InputDecoration(labelText: 'API Key'),
            obscureText: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _baseCtl,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.deepseek.com/v1',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelCtl,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-chat',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cable),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _enter,
                child: const Text('保存并进入'),
              ),
            ],
          ),
          if (_testMsg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _testMsg!,
                style: TextStyle(
                  color: _testOk == true ? Colors.green : kCinnabar,
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _clearConfig,
            icon: const Icon(Icons.delete_outline, size: 18, color: kCinnabar),
            label: const Text('清除本地配置（含 API Key）',
                style: TextStyle(color: kCinnabar)),
          ),
          const Divider(height: 32),
          _sectionTitle('用户档案（让 TA 更懂你）'),
          if (!_userLoaded)
            TextButton.icon(
              onPressed: _loadUser,
              icon: const Icon(Icons.download),
              label: const Text('载入当前档案'),
            ),
          if (_userLoaded) ...[
            _field(_nameCtl, '你的称呼'),
            _field(_genderCtl, '性别'),
            _field(_birthdayCtl, '生日'),
            _field(_mbtiCtl, 'MBTI'),
            _field(_occCtl, '职业'),
            _field(_hobbiesCtl, '爱好'),
            _field(_bioCtl, '一句话介绍', maxLines: 3),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _saveUser, child: const Text('保存档案')),
          ],
          const Divider(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      );

  Widget _field(TextEditingController c, String label, {int maxLines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label),
        ),
      );
}
