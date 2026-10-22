import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'appearance.dart';
import 'chat_api.dart';
import 'chat_storage.dart';
import 'model_connection.dart';
import 'model_settings.dart';
import 'beta_access.dart';
import 'relay_account.dart';

const ink = Color(0xff17212b);
Color get green => appearance.color('accent');
Color get mist => Color.lerp(green, Colors.white, .86)!;
Color get paper => Color.lerp(green, Colors.white, .965)!;
const muted = Color(0xff39434f);

class Message {
  Message(this.user, this.text, {this.bookmarked = false, DateTime? created})
    : created = created ?? DateTime.now();
  final bool user;
  String text;
  bool bookmarked;
  final DateTime created;
  String? thinking, modelName, provider;
  int? tokens, elapsedMs;
  String status = 'complete';
  String? error;
  Map<String, dynamic> toJson() => {
    'user': user,
    'text': text,
    'bookmarked': bookmarked,
    'created': created.toIso8601String(),
    'thinking': thinking,
    'modelName': modelName,
    'provider': provider,
    'tokens': tokens,
    'elapsedMs': elapsedMs,
    'status': status,
    'error': error,
  };
  factory Message.fromJson(Map<String, dynamic> raw) =>
      Message(
          raw['user'] as bool,
          raw['text'] as String,
          bookmarked: raw['bookmarked'] as bool? ?? false,
          created: DateTime.tryParse(raw['created'] as String? ?? ''),
        )
        ..thinking = raw['thinking'] as String?
        ..modelName = raw['modelName'] as String?
        ..provider = raw['provider'] as String?
        ..tokens = raw['tokens'] as int?
        ..elapsedMs = raw['elapsedMs'] as int?
        ..status = raw['status'] == 'pending'
            ? 'cancelled'
            : raw['status'] as String? ?? 'complete'
        ..error = raw['status'] == 'pending'
            ? '上次回复已中断，可重新生成。'
            : raw['error'] as String?;
}

class Persona {
  Persona(
    this.name,
    this.subtitle,
    this.prompt,
    this.group,
    this.color,
    this.icon,
  );
  String name, subtitle, prompt, group;
  Uint8List? avatar;
  Map<String, String> card = {};
  String get compiledPrompt => [
    prompt,
    for (final e in card.entries)
      if (e.value.trim().isNotEmpty && e.key != '开场白') '${e.key}：${e.value}',
  ].where((s) => s.trim().isNotEmpty).join('\n\n');
  final Color color;
  final IconData icon;
  Map<String, dynamic> toJson() => {
    'name': name,
    'subtitle': subtitle,
    'prompt': prompt,
    'group': group,
    'card': card,
    'color': color.toARGB32(),
    'icon': icon.codePoint,
    if (avatar != null) 'avatar': base64Encode(avatar!),
  };
  factory Persona.fromJson(Map<String, dynamic> raw) =>
      Persona(
          raw['name'] as String,
          raw['subtitle'] as String,
          raw['prompt'] as String,
          raw['group'] as String,
          Color(raw['color'] as int),
          [
                Icons.auto_awesome_outlined,
                Icons.crop_free,
                Icons.edit_note,
                Icons.face_outlined,
              ].where((icon) => icon.codePoint == raw['icon']).firstOrNull ??
              Icons.auto_awesome_outlined,
        )
        ..avatar = _readAvatar(raw['avatar'])
        ..card = {
          for (final e
              in (raw['card'] is Map
                  ? (raw['card'] as Map).entries
                  : <MapEntry>[]))
            if (e.key is String && e.value is String)
              e.key as String: (e.value as String).substring(
                0,
                (e.value as String).length.clamp(0, 6000),
              ),
        };

  static Uint8List? _readAvatar(dynamic encoded) {
    if (encoded is! String || encoded.length > 410000) return null;
    try {
      final bytes = base64Decode(encoded);
      return bytes.length <= 300 * 1024 ? bytes : null;
    } catch (_) {
      return null;
    }
  }
}

class Conversation {
  Conversation(
    this.title,
    this.messages, {
    this.usage = const ConversationUsage(),
  });
  String title;
  List<Message> messages;
  ConversationUsage usage;
  int usedTokens = 0;
  String draft = '';
  Map<String, dynamic> toJson() => {
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'usedTokens': usedTokens,
    'draft': draft,
  };
  factory Conversation.fromJson(Map<String, dynamic> raw) =>
      Conversation(
          raw['title'] as String,
          (raw['messages'] as List)
              .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
              .toList(),
        )
        ..usedTokens = raw['usedTokens'] as int? ?? 0
        ..draft = raw['draft'] as String? ?? '';
}

/// Provider-reported statistics. Null means unavailable, never an estimate from
/// the local scripted reply. Ratios use the range 0–1.
class ConversationUsage {
  const ConversationUsage({
    this.steps,
    this.tokensPerSecond,
    this.totalTokens,
    this.cacheHitRate,
    this.contextUsage,
  });

  final int? steps, totalTokens;
  final double? tokensPerSecond, cacheHitRate, contextUsage;
}

class DemoStore extends ChangeNotifier {
  DemoStore({
    ChatApi? api,
    ModelSettings? settings,
    ChatStorage? storage,
    BetaAccess? beta,
    RelayAccount? account,
  }) : _api = api ?? ChatApi(),
       models = settings ?? modelSettings,
       _storage = storage ?? ChatStorage(),
       beta = beta ?? betaAccess,
       account = account ?? relayAccount {
    appearance.addListener(_appearanceChanged);
    models.addListener(changed);
    this.beta.addListener(changed);
    this.account.addListener(changed);
  }
  final ChatApi _api;
  final ChatStorage _storage;
  final ModelSettings models;
  final BetaAccess beta;
  final RelayAccount account;
  bool useBeta = false;
  bool useAccount = false;
  Map<String, String> userCard = {};
  ModelConnection? get activeConnection => useBeta
      ? beta.connection
      : useAccount
      ? account.connection
      : models.active;
  ChatSession? _session;
  Message? _pending;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  int _generation = 0;
  bool _archiveBlocked = false;
  bool _ready = false, _disposed = false;
  String? lastError, storageError;
  Map<String, dynamic> _previousAppearance = appearance.values;
  void _appearanceChanged() {
    final current = appearance.values;
    const optics = {
      'inputBlur',
      'toolbarBlur',
      'inputOpacity',
      'toolbarOpacity',
      'leftOpacity',
      'rightOpacity',
      'userOpacity',
      'assistantOpacity',
      'backgroundEnabled',
      'backgroundOpacity',
      'videoAsset',
      'videoBlur',
      'videoDim',
    };
    final old = Map.of(_previousAppearance)
      ..removeWhere((k, v) => optics.contains(k));
    final next = Map.of(current)..removeWhere((k, v) => optics.contains(k));
    _previousAppearance = current;
    if (!mapEquals(old, next)) changed();
  }

  final conversations = <Conversation>[Conversation('新的对话', [])];
  int conversation = 0;
  final personas = <Persona>[
    Persona(
      'Skivu',
      '聊聊日常，也一起探索新的想法',
      '用清晰、温和的语言，帮助用户拆解问题。',
      '日常',
      green,
      Icons.auto_awesome_outlined,
    ),
    Persona(
      '灵感搭子',
      '给普通的想法，一个新角度',
      '从不同角度展开创意，提出具体的小实验。',
      '创作',
      Color(0xffab805c),
      Icons.auto_awesome_outlined,
    ),
    Persona(
      '专注伙伴',
      '把复杂的事情，轻轻拆开',
      '帮助用户设定优先级，逐步推进任务。',
      '工作',
      Color(0xff7286a5),
      Icons.crop_free,
    ),
    Persona(
      '文字编辑',
      '让表达，更接近你的心意',
      '保留作者语气，优化结构与表达。',
      '创作',
      Color(0xff9384a6),
      Icons.edit_note,
    ),
  ];
  final groups = <String>['全部', '日常', '工作', '创作'];
  int persona = 0;
  String get model =>
      activeConnection?.model ??
      (useBeta
          ? '选择内测模型'
          : useAccount
          ? '登录中转站'
          : '选择模型');
  bool get dark => appearance.dark;
  set dark(bool v) => appearance.set('mode', v ? 'dark' : 'light');
  bool get compact => appearance.flag('compact');
  set compact(bool v) => appearance.set('compact', v);
  bool streaming = false, mutedCall = false;
  bool callActive = false, speaking = false, attached = false;
  double get textScale => appearance.number('textScale');
  set textScale(double v) => appearance.set('textScale', v);
  final prefs = AppearanceSwitches({
    '跟随系统': true,
    '流式显示': true,
    '声音反馈': false,
    '减少动态效果': false,
    '文件读取': false,
    '浏览器访问': false,
    '终端执行': false,
    '允许本机访问': true,
    '草稿自动保留': true,
    '毛玻璃效果': true,
  });
  final installed = <String>{'灵感笔记'};
  String voice = '清澈', recognition = '浏览器演示识别';
  String workspaceName = '灵感空间';
  String workspaceDraft =
      '# 给新的一周留白\n\n最重要的一件事\n让 ski 的第一个想法，成为可触摸的界面。\n\n待办\n☐ 聚焦一个目标\n☐ 留出 30 分钟\n☐ 在周五回顾\n\n这是可编辑的内存演示笔记。';
  List<Message> get messages => conversations[conversation].messages;
  Persona get role => personas[persona];
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    try {
      final text = await _storage.read();
      if (text == null) return;
      final raw = jsonDecode(text) as Map<String, dynamic>;
      if (raw['schema'] != 'skivu-chats-v1') throw const FormatException();
      final loaded = (raw['conversations'] as List)
          .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c)))
          .toList();
      final roles = (raw['personas'] as List?)
          ?.map((p) => Persona.fromJson(Map<String, dynamic>.from(p)))
          .toList();
      conversations
        ..clear()
        ..addAll(loaded.isEmpty ? [Conversation('新的对话', [])] : loaded);
      conversation = (raw['selected'] as int? ?? 0).clamp(
        0,
        conversations.length - 1,
      );
      if (roles?.isNotEmpty == true) {
        personas
          ..clear()
          ..addAll(roles!);
      }
      persona = (raw['persona'] as int? ?? 0).clamp(0, personas.length - 1);
      userCard = {
        for (final e
            in (raw['userCard'] is Map
                ? (raw['userCard'] as Map).entries
                : <MapEntry>[]))
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
      useBeta = false;
      useAccount = raw['useAccount'] == true || raw['useBeta'] == true;
      if (raw['useBeta'] == true) await account.selectFunding('beta');
      if (raw['groups'] is List) {
        groups
          ..clear()
          ..addAll((raw['groups'] as List).whereType<String>().toSet());
        if (!groups.contains('全部')) groups.insert(0, '全部');
      }
    } catch (_) {
      _archiveBlocked = true;
      storageError = '聊天记录读取失败，原记录已保留。请在数据设置中处理后再保存。';
    } finally {
      _ready = true;
    }
    changed();
  }

  String exportChats() => jsonEncode({
    'schema': 'skivu-chats-v1',
    'selected': conversation,
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'personas': personas.map((p) => p.toJson()).toList(),
    'persona': persona,
    'groups': groups,
    'userCard': userCard,
    'useBeta': useBeta,
    'useAccount': useAccount,
  });

  Future<void> saveChats() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_archiveBlocked || !_ready || _disposed) return Future.value();
    final snapshot = exportChats();
    _writes = _writes
        .then((_) => _storage.write(snapshot))
        .then((_) {
          if (storageError != null) {
            storageError = null;
            changed();
          }
        })
        .catchError((Object _) {
          storageError = '聊天记录未能保存，请检查设备存储空间。';
          changed();
        });
    return _writes;
  }

  void _saveSoon() {
    if (!_ready || _disposed || _archiveBlocked) return;
    _saveTimer ??= Timer(const Duration(milliseconds: 800), () {
      _saveTimer = null;
      saveChats();
    });
  }

  void saveDraft(Conversation target, String text) {
    target.draft = text;
    _saveSoon();
  }

  Future<void> clearChats() async {
    stop();
    await _writes;
    await _storage.write(
      jsonEncode({
        'schema': 'skivu-chats-v1',
        'selected': 0,
        'conversations': [],
        'personas': personas.map((p) => p.toJson()).toList(),
        'persona': persona,
        'groups': groups,
        'userCard': userCard,
      }),
    );
    _archiveBlocked = false;
    storageError = null;
    conversations
      ..clear()
      ..add(Conversation('新的对话', []));
    conversation = 0;
    changed();
  }

  Future<void> importChats(String text) async {
    final raw = jsonDecode(text) as Map<String, dynamic>;
    if (raw['schema'] != 'skivu-chats-v1') throw const FormatException();
    final loaded = (raw['conversations'] as List)
        .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c)))
        .toList();
    final roles = (raw['personas'] as List?)
        ?.map((p) => Persona.fromJson(Map<String, dynamic>.from(p)))
        .toList();
    stop();
    await _writes;
    await _storage.write(text);
    conversations
      ..clear()
      ..addAll(loaded.isEmpty ? [Conversation('新的对话', [])] : loaded);
    conversation = (raw['selected'] as int? ?? 0).clamp(
      0,
      conversations.length - 1,
    );
    if (roles?.isNotEmpty == true) {
      personas
        ..clear()
        ..addAll(roles!);
    }
    persona = (raw['persona'] as int? ?? 0).clamp(0, personas.length - 1);
    if (raw['userCard'] is Map)
      userCard = {
        for (final e in (raw['userCard'] as Map).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    if (raw['groups'] is List) {
      groups
        ..clear()
        ..addAll((raw['groups'] as List).whereType<String>().toSet());
      if (!groups.contains('全部')) groups.insert(0, '全部');
    }
    _archiveBlocked = false;
    storageError = null;
    changed();
  }

  void newChat() {
    stop();
    conversations.insert(
      0,
      Conversation('新的对话', [
        if ((role.card['开场白'] ?? '').trim().isNotEmpty)
          Message(false, role.card['开场白']!),
      ]),
    );
    conversation = 0;
    changed();
    saveChats();
  }

  void selectChat(int index) {
    stop();
    conversation = index;
    changed();
    saveChats();
  }

  void stop() {
    _generation++;
    _session?.cancel();
    _session = null;
    if (_pending?.status == 'pending') {
      _pending!.status = 'cancelled';
      _pending!.error = '已停止生成';
    }
    _pending = null;
    streaming = false;
    changed();
    saveChats();
  }

  bool send(String input) {
    if (input.trim().isEmpty || streaming) return false;
    final config = activeConnection;
    if (config == null) {
      lastError = useBeta
          ? '请先检查内测配对状态与可用模型。'
          : useAccount
          ? (account.signedIn && account.funding == 'beta'
                ? account.betaMessage
                : '请先登录中转站并同步模型。')
          : '请先添加一个模型连接。';
      changed();
      return false;
    }
    messages.add(Message(true, input.trim()));
    if (messages.length == 1)
      conversations[conversation].title = input.trim().length > 14
          ? input.trim().substring(0, 14)
          : input.trim();
    attached = false;
    _begin(config);
    return true;
  }

  void regenerate() {
    if (streaming ||
        activeConnection == null ||
        messages.isEmpty ||
        messages.last.user)
      return;
    messages.removeLast();
    _begin(activeConnection!);
  }

  void _begin(ModelConnection config) {
    lastError = null;
    final target = conversations[conversation];
    final history = messages
        .where((m) => m.user || (m.text.isNotEmpty && m.status != 'failed'))
        .map((m) => {'role': m.user ? 'user' : 'assistant', 'content': m.text})
        .toList();
    final answer = Message(false, '')
      ..status = 'pending'
      ..modelName = config.model
      ..provider = config.provider;
    messages.add(answer);
    _pending = answer;
    streaming = true;
    final generation = ++_generation;
    final prompt =
        [
              role.compiledPrompt,
              if (userCard.values.any((v) => v.trim().isNotEmpty))
                '用户角色资料：\n${userCard.entries.map((e) => '${e.key}：${e.value}').join('\n')}',
            ]
            .where((v) => v.isNotEmpty)
            .join('\n\n')
            .replaceAll('{{char}}', role.name)
            .replaceAll(
              '{{user}}',
              userCard['称呼']?.trim().isNotEmpty == true
                  ? userCard['称呼']!
                  : '用户',
            );
    saveChats();
    changed();
    unawaited(
      _generate(
        target,
        answer,
        config,
        history,
        prompt,
        generation,
        useBeta,
        useAccount && !useBeta,
      ),
    );
  }

  Future<void> _generate(
    Conversation target,
    Message answer,
    ModelConnection config,
    List<Map<String, String>> history,
    String prompt,
    int generation,
    bool betaRequest,
    bool accountRequest,
  ) async {
    final watch = Stopwatch()..start();
    var usage = const ApiUsage();
    try {
      final key = betaRequest || accountRequest
          ? ''
          : await models.keyFor(config.id);
      if (generation != _generation) return;
      if (!betaRequest &&
          !accountRequest &&
          key.isEmpty &&
          config.auth != 'none' &&
          !['Ollama', 'LM Studio'].contains(config.provider))
        throw const ChatFailure('此连接未填写 API Key，请在模型设置中补充。');
      final session = betaRequest
          ? beta.startChat(history, prompt)
          : accountRequest
          ? account.startChat(history, prompt)
          : _api.start(config, key, history, prompt);
      _session = session;
      await for (final event in session.events) {
        if (generation != _generation) return;
        answer.text += event.text;
        if (event.thinking.isNotEmpty)
          answer.thinking = '${answer.thinking ?? ''}${event.thinking}';
        if (event.usage != null) usage = usage.merge(event.usage!);
        if (event.limited) answer.error = '已达到输出上限，可在模型设置中增加最大输出。';
        answer.elapsedMs = watch.elapsedMilliseconds;
        answer.tokens = usage.output;
        target.usage = ConversationUsage(
          totalTokens: usage.input != null && usage.output != null
              ? target.usedTokens + usage.input! + usage.output!
              : (target.usedTokens > 0 ? target.usedTokens : null),
          tokensPerSecond:
              usage.output == null || watch.elapsedMilliseconds == 0
              ? null
              : usage.output! * 1000 / watch.elapsedMilliseconds,
          cacheHitRate:
              usage.cached != null && usage.input != null && usage.input! > 0
              ? usage.cached! / usage.input!
              : null,
          contextUsage:
              config.contextLimit != null &&
                  usage.input != null &&
                  config.contextLimit! > 0
              ? usage.input! / config.contextLimit!
              : null,
        );
        _saveSoon();
        changed();
      }
      if (generation != _generation) return;
      if (answer.text.trim().isEmpty)
        throw const ChatFailure('服务没有返回文字回复，请检查模型、输出上限或重试。');
      answer.status = 'complete';
    } catch (e) {
      if (generation != _generation) return;
      if (accountRequest &&
          e is ChatFailure &&
          e.code == 'APP_SESSION_INVALID') {
        try {
          await account.invalidate();
        } catch (_) {}
      }
      answer.status = 'failed';
      answer.error = e is ChatFailure
          ? e.message
          : '读取连接配置失败，请重新保存 API Key 后重试。';
    } finally {
      if (accountRequest && account.signedIn) unawaited(account.refresh());
      watch.stop();
      if (generation == _generation) {
        answer.elapsedMs = watch.elapsedMilliseconds;
        if (usage.input != null && usage.output != null)
          target.usedTokens += usage.input! + usage.output!;
        streaming = false;
        _pending = null;
        _session = null;
        saveChats();
        changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    appearance.removeListener(_appearanceChanged);
    models.removeListener(changed);
    beta.removeListener(changed);
    account.removeListener(changed);
    _generation++;
    _session?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}

class AppearanceSwitches extends MapBase<String, bool> {
  AppearanceSwitches(this._other);
  final Map<String, bool> _other;
  String? _key(Object? key) => key == '毛玻璃效果'
      ? 'glass'
      : key == '减少动态效果'
      ? 'reduceMotion'
      : null;
  @override
  bool? operator [](Object? key) {
    final k = _key(key);
    return k == null ? _other[key] : appearance.flag(k);
  }

  @override
  void operator []=(String key, bool value) {
    final k = _key(key);
    if (k == null) {
      _other[key] = value;
    } else {
      appearance.set(k, value);
    }
  }

  @override
  Iterable<String> get keys => _other.keys;
  @override
  void clear() => _other.clear();
  @override
  bool? remove(Object? key) => _other.remove(key);
}

final demo = DemoStore();
