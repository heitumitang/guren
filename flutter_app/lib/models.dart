/// 数据模型层。
///
/// 全部按 server/main.py 的真实 JSON 契约手写 fromJson / toJson，
/// 不依赖 json_serializable（无需 build_runner）。
/// Persona 用 Map 包装 + typed accessors，避免与后端 schema 版本耦合导致编译失败。

// ---------------- LLM 配置（对应后端 LLMIn）----------------

class LLMConfig {
  final String apiKey;
  final String baseUrl; // 模型提供方 base url
  final String model;

  const LLMConfig({this.apiKey = '', this.baseUrl = '', this.model = ''});

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'base_url': baseUrl,
        'model': model,
      };

  factory LLMConfig.fromJson(Map<String, dynamic> j) => LLMConfig(
        apiKey: (j['api_key'] ?? '').toString(),
        baseUrl: (j['base_url'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
      );

  bool get isEmpty => apiKey.isEmpty && baseUrl.isEmpty && model.isEmpty;

  LLMConfig copyWith({String? apiKey, String? baseUrl, String? model}) => LLMConfig(
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
      );
}

// ---------------- 用户档案（对应后端 UserIn / empty_user）----------------

class UserProfile {
  final String name;
  final String gender;
  final String birthday;
  final String mbti;
  final String occupation;
  final String hobbies;
  final String bio;

  const UserProfile({
    this.name = '',
    this.gender = '',
    this.birthday = '',
    this.mbti = '',
    this.occupation = '',
    this.hobbies = '',
    this.bio = '',
  });

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        name: (j['name'] ?? '').toString(),
        gender: (j['gender'] ?? '').toString(),
        birthday: (j['birthday'] ?? '').toString(),
        mbti: (j['mbti'] ?? '').toString(),
        occupation: (j['occupation'] ?? '').toString(),
        hobbies: (j['hobbies'] ?? '').toString(),
        bio: (j['bio'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'gender': gender,
        'birthday': birthday,
        'mbti': mbti,
        'occupation': occupation,
        'hobbies': hobbies,
        'bio': bio,
      };

  UserProfile copyWith({
    String? name,
    String? gender,
    String? birthday,
    String? mbti,
    String? occupation,
    String? hobbies,
    String? bio,
  }) =>
      UserProfile(
        name: name ?? this.name,
        gender: gender ?? this.gender,
        birthday: birthday ?? this.birthday,
        mbti: mbti ?? this.mbti,
        occupation: occupation ?? this.occupation,
        hobbies: hobbies ?? this.hobbies,
        bio: bio ?? this.bio,
      );
}

// ---------------- 人物索引项（对应 GET /characters 数组元素）----------------

class CharacterIndex {
  final String id;
  final String name;
  final String emoji;
  final String avatar;
  final String relation;
  final Map<String, String> basics;
  final String createdAt;
  final String updatedAt;
  final int unread;

  CharacterIndex.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        name = (j['name'] ?? '未命名').toString(),
        emoji = (j['emoji'] ?? '🙂').toString(),
        avatar = (j['avatar'] ?? '').toString(),
        relation = (j['relation'] ?? '').toString(),
        basics = Map<String, String>.from(
          ((j['basics'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v.toString()))),
        ),
        createdAt = (j['created_at'] ?? '').toString(),
        updatedAt = (j['updated_at'] ?? '').toString(),
        unread = (j['unread'] as num? ?? 0).toInt();
}

// ---------------- 人格档案（包装后端完整 persona.json）----------------

class Persona {
  final Map<String, dynamic> raw;

  Persona(this.raw);

  String get name => (((raw['meta'] as Map?)?['target_name']) ?? '未命名').toString();
  String get emoji => (raw['emoji'] ?? '🙂').toString();
  String get avatar => (raw['avatar'] ?? '').toString();
  String get relation => (((raw['relationship'] as Map?)?['bond']) ?? '').toString();
  String get callMe => (((raw['relationship'] as Map?)?['call_me']) ?? '').toString();
  String get relContext => (((raw['relationship'] as Map?)?['context']) ?? '').toString();

  List<dynamic> get traits => (raw['traits'] as List? ?? []);
  List<dynamic> get flaws => (raw['flaws'] as List? ?? []);
  List<dynamic> get relations => (raw['relations'] as List? ?? []);

  double get flawScale => ((raw['flaw_intensity_scale'] as num? ?? 0.7)).toDouble();
  double get replyRate =>
      ((((raw['behavior'] as Map?)?['reply_rate']) as num? ?? 0.7)).toDouble();
  String get reviewStatus => (raw['review_status'] ?? '').toString();

  String get basicsAge => (basics['age'] ?? '').toString();
  String get basicsOccupation => (basics['occupation'] ?? '').toString();
  String get basicsMbti => (basics['mbti'] ?? '').toString();
  Map<String, dynamic> get basics =>
      Map<String, dynamic>.from(raw['basics'] as Map? ?? {});
}

// ---------------- 聊天消息 ----------------

/// 消息去重键：时间戳一律归一化到秒。
///
/// 历史里的 at 是 DateTime（toIso8601String 会带 .000），收件箱里的 at 是后端写的
/// 秒级字符串（不带 .000）——两边格式不同会算出不同的 key，同一条消息就会显示两次。
String dedupeKey(String atRaw, String text) {
  final d = DateTime.tryParse(atRaw);
  return '${d == null ? atRaw : d.toIso8601String().substring(0, 19)}|$text';
}

class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime at;
  final bool read; // 对方已读（已读不回）标记

  ChatMessage({required this.role, required this.content, required this.at, this.read = false});

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: (j['role'] ?? 'user').toString(),
        content: (j['content'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        read: j['read'] as bool? ?? false,
      );

  String get key => dedupeKey(at.toIso8601String(), content);
}

// ---------------- 引用回复 ----------------

class Quote {
  final String role; // 'user' | 'assistant'
  final String text;

  Quote({required this.role, required this.text});

  Map<String, dynamic> toJson() => {'role': role, 'text': text};
}

// ---------------- 聊天返回（涵盖 immediate / delayed / 不回 / 拦截）----------------

class ChatResult {
  final bool willReply;
  final bool? delivered;
  final String? text;
  final bool? blocked;
  final String? reason;
  final String? replyAt;
  final int? delaySec;
  final String? taskId;
  final bool? raw;

  ChatResult.fromJson(Map<String, dynamic> j)
      : willReply = j['will_reply'] as bool? ?? true,
        delivered = j['delivered'] as bool?,
        text = j['text'] as String?,
        blocked = j['blocked'] as bool?,
        reason = j['reason'] as String?,
        replyAt = j['reply_at'] as String?,
        delaySec = j['delay_sec'] as int?,
        taskId = j['task_id'] as String?,
        raw = j['raw'] as bool?;
}

// ---------------- 收件箱（延迟投递的消息）----------------

class OutboxItem {
  final String id;
  final String type;
  final String at;
  final String text;
  final bool blocked;
  final String? reason;
  final bool delivered;

  OutboxItem.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        type = (j['type'] ?? '').toString(),
        at = (j['at'] ?? '').toString(),
        text = (j['text'] ?? '').toString(),
        blocked = j['blocked'] as bool? ?? false,
        reason = j['reason'] as String?,
        delivered = j['delivered'] as bool? ?? false;
}

// ---------------- 时间表预览（对应 schedule/preview）----------------

class SchedulePreview {
  final bool online;
  final bool willReply;
  final int delaySec;
  final String? replyAt;
  final String reason;

  SchedulePreview.fromJson(Map<String, dynamic> j)
      : online = j['online'] as bool? ?? true,
        willReply = j['will_reply'] as bool? ?? true,
        delaySec = j['delay_sec'] as int? ?? 0,
        replyAt = j['reply_at'] as String?,
        reason = (j['reason'] ?? '').toString();
}

// ---------------- 主动发起（proactive）----------------

class ProactiveResult {
  final bool initiated;
  final String? text;
  final bool? blocked;
  final String? reason;

  ProactiveResult.fromJson(Map<String, dynamic> j)
      : initiated = j['initiated'] as bool? ?? false,
        text = j['text'] as String?,
        blocked = j['blocked'] as bool?,
        reason = j['reason'] as String?;
}

// ---------------- 预设 ----------------

class Preset {
  final String id;
  final String name;
  final String emoji;
  final String desc;

  Preset.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        name = (j['name'] ?? '').toString(),
        emoji = (j['emoji'] ?? '').toString(),
        // 后端 list_presets 返回的键是 tagline；兼容旧键 desc
        desc = (j['tagline'] ?? j['desc'] ?? '').toString();
}

class PresetsResult {
  final List<Preset> presets;
  PresetsResult.fromJson(Map<String, dynamic> j)
      : presets = ((j['presets'] as List? ?? [])
            .map((e) => Preset.fromJson(e as Map<String, dynamic>))
            .toList());
}

// ---------------- 蒸馏结果 ----------------

class DistillResult {
  final bool ok;
  final String id;
  final List<dynamic> issues;
  final int traits;
  final int flaws;

  DistillResult.fromJson(Map<String, dynamic> j)
      : ok = j['ok'] as bool? ?? false,
        id = (j['id'] ?? '').toString(),
        issues = (j['hallucination_issues'] as List? ?? []),
        traits = j['traits'] as int? ?? 0,
        flaws = j['flaws'] as int? ?? 0;
}

// ---------------- 创建人物返回 ----------------

class CreateResult {
  final String id;
  final Persona persona;

  CreateResult.fromJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        persona = Persona(j['persona'] as Map<String, dynamic>? ?? {});
}

// ---------------- API key 测试返回 ----------------

class ConfigTestResult {
  final bool ok;
  final String? reply;
  final String? error;
  final Map<String, dynamic>? using;

  ConfigTestResult.fromJson(Map<String, dynamic> j)
      : ok = j['ok'] as bool? ?? false,
        reply = j['reply'] as String?,
        error = j['error'] as String?,
        using = j['using'] as Map<String, dynamic>?;
}

// ---------------- OCR 返回 ----------------

class OcrResult {
  final List<dynamic> messages;
  final int nTarget;
  final int nUser;
  final String? warn;

  OcrResult.fromJson(Map<String, dynamic> j)
      : messages = (j['messages'] as List? ?? []),
        nTarget = j['n_target'] as int? ?? 0,
        nUser = j['n_user'] as int? ?? 0,
        warn = j['warn'] as String?;
}
