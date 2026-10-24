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
import 'stream_reveal.dart';
import 'chat_interaction.dart';
import 'companion_library.dart';

const appToolbarHeight = 64.0;
Color get ink => appearance.textColor('interfaceText');
Color get green => appearance.color('accent');
Color get mist => Color.lerp(green, Colors.white, .86)!;
Color get paper => Color.lerp(green, Colors.white, .965)!;
Color get muted => appearance.textColorEnabled('interfaceText')
    ? appearance.textColor('interfaceText')
    : const Color(0xff39434f);
int _localSequence = 0;
String _localId(String kind) =>
    '$kind-${DateTime.now().microsecondsSinceEpoch}-${_localSequence++}';

class Message {
  Message(this.user, this.text, {this.bookmarked = false, DateTime? created})
    : created = created ?? DateTime.now();
  final bool user;
  String text;
  bool bookmarked;
  bool unread = false;
  final DateTime created;
  String? thinking, modelName, provider;
  int? tokens, elapsedMs;
  String status = 'complete';
  String? error;
  String? contextNotice;
  bool? requestStreaming;
  String? authorId;
  String kind = 'text';
  String? stickerId, turnId, imageData;
  bool described = false;
  String get modelText => switch (kind) {
    'voice' => '${described ? '[用户描述的一条语音，内容]' : '[用户发来的语音，转写内容]'} $text',
    'photo' => '[用户描述的一张照片] $text',
    'image' => '[用户上传的照片] $text',
    'sticker' => '[用户发送表情包：$text]',
    _ => text,
  };
  Map<String, String> get apiMessage => {
    'role': user ? 'user' : 'assistant',
    'content': modelText,
    if (imageData != null) 'image': imageData!,
  };
  Map<String, dynamic> toJson() => {
    'user': user,
    'text': text,
    'bookmarked': bookmarked,
    'unread': unread,
    'created': created.toIso8601String(),
    'thinking': thinking,
    'modelName': modelName,
    'provider': provider,
    'tokens': tokens,
    'elapsedMs': elapsedMs,
    'status': status,
    'error': error,
    'contextNotice': contextNotice,
    'requestStreaming': requestStreaming,
    'authorId': authorId,
    'kind': kind,
    'stickerId': stickerId,
    'turnId': turnId,
    'imageData': imageData,
    'described': described,
  };
  factory Message.fromJson(Map<String, dynamic> raw) =>
      Message(
          raw['user'] as bool,
          raw['text'] as String,
          bookmarked: raw['bookmarked'] as bool? ?? false,
          created: DateTime.tryParse(raw['created'] as String? ?? ''),
        )
        ..requestStreaming = raw['requestStreaming'] is bool
            ? raw['requestStreaming']
            : null
        ..contextNotice = raw['contextNotice'] is String
            ? raw['contextNotice']
            : null
        ..thinking = raw['thinking'] as String?
        ..unread =
            raw['unread'] == true &&
            raw['user'] == false &&
            raw['status'] == 'complete'
        ..authorId = raw['authorId'] is String ? raw['authorId'] : null
        ..kind =
            ['text', 'voice', 'photo', 'image', 'sticker'].contains(raw['kind'])
            ? raw['kind']
            : 'text'
        ..stickerId = raw['stickerId'] is String ? raw['stickerId'] : null
        ..turnId = raw['turnId'] is String ? raw['turnId'] : null
        ..imageData = validChatImage(raw['imageData']) ? raw['imageData'] : null
        ..described = raw['described'] == true
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
    this.icon, {
    String? id,
  }) : id = id ?? _localId('role');
  final String id;
  String name, subtitle, prompt, group;
  Uint8List? avatar;
  Map<String, String> card = {};
  String? worldId, sceneId;
  String get compiledPrompt => [
    prompt,
    for (final e in card.entries)
      if (e.value.trim().isNotEmpty && e.key != '开场白') '${e.key}：${e.value}',
  ].where((s) => s.trim().isNotEmpty).join('\n\n');
  final Color color;
  final IconData icon;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'prompt': prompt,
    'group': group,
    'card': card,
    'worldId': worldId,
    'sceneId': sceneId,
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
          id: raw['id'] as String?,
        )
        ..avatar = _readAvatar(raw['avatar'])
        ..worldId = raw['worldId'] is String ? raw['worldId'] : null
        ..sceneId = raw['sceneId'] is String ? raw['sceneId'] : null
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
    String? id,
    this.personaId,
    this.pinned = false,
    this.muted = false,
    this.replyReminder = false,
    this.chatBackground,
    this.titleEdited = false,
    this.placeholder = false,
  }) : id = id ?? _localId('chat');
  final String id;
  String? personaId;
  bool pinned, titleEdited, placeholder, muted, replyReminder;
  bool confirmBeforeReply = false;
  List<Message> get queuedMessages =>
      messages.where((m) => m.user && m.status == 'queued').toList();
  String? chatBackground;
  static bool validBackground(String value) =>
      value.length <= 180000 &&
      RegExp(
        r'^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$',
      ).hasMatch(value);
  String title;
  List<Message> messages;
  int get unreadCount => messages
      .where((m) => !m.user && m.status == 'complete' && m.unread)
      .length;
  ConversationUsage usage;
  int usedTokens = 0;
  String draft = '';
  List<Map<String, dynamic>> interactions = [];
  Set<String> hiddenInteractions = {};
  DateTime? interactionsClearedAt;
  List<String> groupMembers = [];
  String groupRule = 'manual';
  String groupKind = 'group';
  int groupMaxReplies = 1, groupHistoryLimit = 20;
  Map<String, dynamic> toJson() => {
    'id': id,
    'personaId': personaId,
    'pinned': pinned,
    'muted': muted,
    'replyReminder': replyReminder,
    'confirmBeforeReply': confirmBeforeReply,
    'chatBackground': chatBackground,
    'titleEdited': titleEdited,
    'placeholder': placeholder,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'usedTokens': usedTokens,
    'draft': draft,
    'interactions': interactions,
    'hiddenInteractions': hiddenInteractions.toList(),
    'interactionsClearedAt': interactionsClearedAt?.toIso8601String(),
    'groupMembers': groupMembers,
    'groupKind': groupKind,
    'groupRule': groupRule,
    'groupMaxReplies': groupMaxReplies,
    'groupHistoryLimit': groupHistoryLimit,
  };
  factory Conversation.fromJson(Map<String, dynamic> raw) =>
      Conversation(
          raw['title'] as String,
          (raw['messages'] as List)
              .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
              .toList(),
          id: raw['id'] as String?,
          personaId: raw['personaId'] as String?,
          pinned: raw['pinned'] == true,
          muted: raw['muted'] == true,
          replyReminder: raw['replyReminder'] == true,
          chatBackground:
              raw['chatBackground'] is String &&
                  validBackground(raw['chatBackground'] as String)
              ? raw['chatBackground'] as String
              : null,
          titleEdited: raw['titleEdited'] == true,
          placeholder:
              raw['placeholder'] == true &&
              (raw['messages'] as List).isEmpty &&
              (raw['draft'] as String? ?? '').trim().isEmpty,
        )
        ..usedTokens = raw['usedTokens'] as int? ?? 0
        ..confirmBeforeReply = raw['confirmBeforeReply'] == true
        ..draft = raw['draft'] as String? ?? ''
        ..interactions =
            (raw['interactions'] is List ? raw['interactions'] as List : [])
                .whereType<Map>()
                .take(100)
                .map(cleanChatInteraction)
                .whereType<Map<String, dynamic>>()
                .toList()
        ..hiddenInteractions =
            (raw['hiddenInteractions'] is List
                    ? raw['hiddenInteractions'] as List
                    : [])
                .whereType<String>()
                .where((id) => id.length <= 100)
                .take(1000)
                .toSet()
        ..interactionsClearedAt = DateTime.tryParse(
          raw['interactionsClearedAt'] is String
              ? raw['interactionsClearedAt']
              : '',
        )
        ..groupMembers =
            (raw['groupMembers'] is List ? raw['groupMembers'] as List : [])
                .whereType<String>()
                .where((id) => id.isNotEmpty && id.length <= 100)
                .toSet()
                .take(8)
                .toList()
        ..groupRule =
            [
              'manual',
              'mentions',
              'roundRobin',
              'automatic',
            ].contains(raw['groupRule'])
            ? raw['groupRule']
            : 'manual'
        ..groupKind = raw['groupKind'] == 'channel' ? 'channel' : 'group'
        ..groupMaxReplies = raw['groupMaxReplies'] is int
            ? (raw['groupMaxReplies'] as int).clamp(1, 6)
            : 1
        ..groupHistoryLimit = raw['groupHistoryLimit'] is int
            ? (raw['groupHistoryLimit'] as int).clamp(5, 100)
            : 20;
}

class ClearedChatMessages {
  ClearedChatMessages(this.chat)
    : messages = List.of(chat.messages),
      interactions = List.of(chat.interactions),
      clearedAt = chat.interactionsClearedAt,
      usedTokens = chat.usedTokens,
      usage = chat.usage;
  final Conversation chat;
  final List<Message> messages;
  final List<Map<String, dynamic>> interactions;
  final DateTime? clearedAt;
  final int usedTokens;
  final ConversationUsage usage;
  bool restored = false;
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
    conversations.first.personaId = personas.first.id;
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
  final Map<Object, String> _chatReaders = {};
  bool _chatForeground = true;

  /// A selected conversation is read only while a chat surface is visible.
  void setChatReader(Object owner, String? chatId) {
    if (chatId == null) {
      _chatReaders.remove(owner);
      return;
    }
    _chatReaders[owner] = chatId;
    if (_chatForeground) markChatRead(chatId);
  }

  void setChatForeground(bool value) {
    _chatForeground = value;
    if (value) {
      for (final id in _chatReaders.values.toSet()) {
        markChatRead(id);
      }
    }
  }

  void markChatRead(String id) {
    final chat = conversations.where((c) => c.id == id).firstOrNull;
    if (chat == null || chat.unreadCount == 0) return;
    for (final message in chat.messages) {
      message.unread = false;
    }
    saveChats();
    changed();
  }

  Map<String, String> userCard = {};
  Uint8List? userAvatar;
  final worlds = <WorldSetting>[];
  final stickerGroups = <StickerGroup>[];
  final stickers = <StickerAsset>[];
  int libraryRevision = 0;
  WorldSetting? worldFor(Persona role) =>
      worlds.where((w) => w.id == role.worldId).firstOrNull;
  StickerAsset? stickerFor(String? id) =>
      stickers.where((s) => s.id == id).firstOrNull;
  String promptFor(Persona role) => [
    role.compiledPrompt,
    if (worldFor(role) case final world?) world.prompt(role.sceneId),
  ].where((v) => v.isNotEmpty).join('\n\n');
  void saveLibrary() {
    libraryRevision++;
    changed();
    saveChats();
  }

  void removeWorld(String id) {
    worlds.removeWhere((w) => w.id == id);
    for (final role in personas.where((p) => p.worldId == id)) {
      role.worldId = null;
      role.sceneId = null;
    }
    saveLibrary();
  }

  void removeWorldEntry(WorldSetting world, String id) {
    world.entries.removeWhere((e) => e.id == id);
    for (final role in personas.where(
      (p) => p.worldId == world.id && p.sceneId == id,
    )) {
      role.sceneId = null;
    }
    saveLibrary();
  }

  void _restoreLibraries(Map raw, {bool validateOnly = false}) {
    final nextWorlds = [
      for (final w in (raw['worlds'] as List? ?? []))
        WorldSetting.fromJson(w as Map),
    ];
    final nextGroups = [
      for (final g in (raw['stickerGroups'] as List? ?? []))
        StickerGroup.fromJson(g as Map),
    ];
    final nextStickers = [
      for (final s in (raw['stickers'] as List? ?? []))
        StickerAsset.fromJson(s as Map),
    ];
    if (nextWorlds.length > 200 ||
        nextGroups.length > 30 ||
        nextStickers.length > 200 ||
        nextStickers.fold<int>(0, (sum, s) => sum + s.data.length) > 8500000 ||
        nextWorlds.map((w) => w.id).toSet().length != nextWorlds.length ||
        nextGroups.map((g) => g.id).toSet().length != nextGroups.length ||
        nextStickers.map((s) => s.id).toSet().length != nextStickers.length ||
        nextWorlds.any(
          (w) =>
              w.id.isEmpty ||
              w.name.trim().isEmpty ||
              w.entries.map((e) => e.id).toSet().length != w.entries.length ||
              w.entries.any((e) => e.id.isEmpty),
        ) ||
        nextGroups.any((g) => g.id.isEmpty || g.name.trim().isEmpty) ||
        nextStickers.any(
          (s) =>
              s.id.isEmpty ||
              (s.active && !nextGroups.any((g) => g.id == s.groupId)),
        ) ||
        (raw['worlds'] as List? ?? []).any(
          (w) => ((w as Map)['entries'] as List? ?? []).length > 100,
        ))
      throw const FormatException('资料库超出限制或标识重复');
    if (validateOnly) return;
    worlds
      ..clear()
      ..addAll(nextWorlds);
    stickerGroups
      ..clear()
      ..addAll(nextGroups);
    stickers
      ..clear()
      ..addAll(nextStickers);
    for (final role in personas) {
      final legacy = role.card['场景与世界观'];
      if (legacy != null && legacy.trim().isNotEmpty && role.worldId == null) {
        final world = WorldSetting(
          id: 'legacy-world-${role.id}',
          name: '${role.name}的原有设定',
          category: '原有设定',
          summary: legacy,
        );
        if (!worlds.any((w) => w.id == world.id)) worlds.add(world);
        role.worldId = world.id;
        role.card.remove('场景与世界观');
      }
      final world = worldFor(role);
      if (world == null) {
        role.worldId = null;
        role.sceneId = null;
      } else if (!world.scenes.any((e) => e.id == role.sceneId)) {
        role.sceneId = null;
      }
    }
    libraryRevision++;
  }

  ModelConnection? get activeConnection => useBeta
      ? beta.connection
      : useAccount
      ? account.connection
      : models.active;
  ChatSession? _session;
  StreamReveal? _reveal;
  Message? _pending;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  bool _savePending = false;
  bool _saveRunning = false;
  bool _archiveTransaction = false;
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

  final conversations = <Conversation>[
    Conversation('新的对话', [], placeholder: true),
  ];
  final Map<String, bool> roleFolders = {};
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
  Persona get role =>
      personas
          .where((p) => p.id == conversations[conversation].personaId)
          .firstOrNull ??
      personas[persona];
  Persona get editingRole => personas[persona];
  Iterable<Conversation> get visibleConversations =>
      conversations.where((c) => !c.placeholder);

  List<Conversation> conversationsFor(String roleId) {
    final chats = visibleConversations
        .where((c) => c.personaId == roleId)
        .toList();
    // Sort a view only: pinning never changes the selected conversation index.
    return [...chats.where((c) => c.pinned), ...chats.where((c) => !c.pinned)];
  }

  bool folderExpanded(String id) => roleFolders[id] ?? id == role.id;
  void toggleFolder(String id) {
    roleFolders[id] = !folderExpanded(id);
    changed();
    saveChats();
  }

  void editCurrentRole() {
    persona = personas.indexOf(role);
  }

  void addPersona(Persona value) {
    if (value.group == '全部') value.group = '未分组';
    if (!groups.contains(value.group)) groups.add(value.group);
    personas.add(value);
    persona = personas.length - 1;
    roleFolders[value.id] = true;
    changed();
    saveChats();
  }

  bool addGroup(String name) {
    final value = name.trim().characters.take(40).join();
    if (value.isEmpty || groups.contains(value)) return false;
    groups.add(value);
    changed();
    saveChats();
    return true;
  }

  bool deleteGroup(String name) {
    if (name == '全部' || name == '未分组' || !groups.contains(name)) return false;
    groups.remove(name);
    for (final role in personas.where((p) => p.group == name)) {
      role.group = '未分组';
      if (!groups.contains('未分组')) groups.add('未分组');
    }
    changed();
    saveChats();
    return true;
  }

  bool removePersona(String id) {
    final target = personas.where((p) => p.id == id).firstOrNull;
    if (target == null || personas.length <= 1) return false;
    final active = conversations[conversation], editorId = editingRole.id;
    for (final chat in conversations.where(
      (c) => c.groupMembers.contains(id),
    )) {
      chat.groupMembers.remove(id);
      if (chat.personaId == id && chat.groupMembers.isNotEmpty)
        chat.personaId = chat.groupMembers.first;
    }
    final activeRemoved = active.personaId == id;
    if (activeRemoved) stop();
    personas.remove(target);
    conversations.removeWhere((c) => c.personaId == id);
    roleFolders.remove(id);
    if (conversations.isEmpty) {
      conversations.add(
        Conversation(
          '新的对话',
          [],
          personaId: personas.first.id,
          placeholder: true,
        ),
      );
    }
    conversation = activeRemoved ? 0 : conversations.indexOf(active);
    final nextRoleId = conversations[conversation].personaId;
    persona = personas.indexWhere((p) => p.id == editorId);
    if (persona < 0) persona = personas.indexWhere((p) => p.id == nextRoleId);
    if (activeRemoved && nextRoleId != null) roleFolders[nextRoleId] = true;
    changed();
    saveChats();
    return true;
  }

  Map<String, dynamic> _normalizeArchive(Map<String, dynamic> raw) {
    _restoreLibraries(raw, validateOnly: true);
    if (raw['schema'] != 'skivu-chats-v1' || raw['conversations'] is! List)
      throw const FormatException();
    final sourceRoles = raw['personas'] as List?;
    final roles = sourceRoles?.isNotEmpty == true
        ? [
            for (var i = 0; i < sourceRoles!.length; i++)
              Persona.fromJson({
                ...Map<String, dynamic>.from(sourceRoles[i]),
                'id': (sourceRoles[i] as Map)['id'] ?? 'legacy-role-$i',
              }),
          ]
        : [...personas];
    final ids = roles.map((p) => p.id).toSet();
    if (ids.length != roles.length || ids.any((id) => id.isEmpty))
      throw const FormatException('角色标识重复或为空');
    final fallback = (raw['persona'] as int? ?? 0).clamp(0, roles.length - 1);
    final chats = (raw['conversations'] as List)
        .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c)))
        .toList();
    for (final chat in chats) {
      chat.personaId ??= roles[fallback].id;
      if (!ids.contains(chat.personaId))
        throw const FormatException('对话所属角色不存在');
      if (chat.groupMembers.any((id) => !ids.contains(id)))
        throw const FormatException('群成员不存在');
    }
    if (chats.isEmpty)
      chats.add(
        Conversation(
          '新的对话',
          [],
          personaId: roles[fallback].id,
          placeholder: true,
        ),
      );
    if (chats.map((c) => c.id).toSet().length != chats.length ||
        chats.any((c) => c.id.isEmpty))
      throw const FormatException('对话标识重复或为空');
    final byId = chats.indexWhere((c) => c.id == raw['selectedId']);
    final selected = byId >= 0
        ? byId
        : (raw['selected'] as int? ?? 0).clamp(0, chats.length - 1);
    return {
      ...raw,
      'personas': roles.map((p) => p.toJson()).toList(),
      'conversations': chats.map((c) => c.toJson()).toList(),
      'selected': selected,
      'selectedId': chats[selected].id,
      'persona': roles.indexWhere((p) => p.id == chats[selected].personaId),
      'roleFolders': {
        if (raw['roleFolders'] is Map)
          for (final e in (raw['roleFolders'] as Map).entries)
            if (ids.contains(e.key) && e.value is bool)
              e.key as String: e.value as bool,
      },
    };
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    try {
      final text = await _storage.readValidated((text) {
        _normalizeArchive(jsonDecode(text) as Map<String, dynamic>);
      });
      if (text == null) return;
      final raw = _normalizeArchive(jsonDecode(text) as Map<String, dynamic>);
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
      roleFolders
        ..clear()
        ..addAll(Map<String, bool>.from(raw['roleFolders'] as Map));
      userCard = {
        for (final e
            in (raw['userCard'] is Map
                ? (raw['userCard'] as Map).entries
                : <MapEntry>[]))
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
      userAvatar = Persona._readAvatar(raw['userAvatar']);
      _restoreLibraries(raw);
      useBeta = false;
      useAccount = raw['useAccount'] == true || raw['useBeta'] == true;
      if (raw['useBeta'] == true)
        await account.selectFunding('beta', refreshRemote: false);
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

  String exportChats() => jsonEncode(_chatSnapshot());
  Future<String> exportChatsAsync() => compute(jsonEncode, _chatSnapshot());
  Map<String, dynamic> _chatSnapshot() => {
    'schema': 'skivu-chats-v1',
    'selected': conversation,
    'selectedId': conversations[conversation].id,
    'roleFolders': roleFolders,
    'conversations': conversations.map((c) => c.toJson()).toList(),
    'personas': personas.map((p) => p.toJson()).toList(),
    'persona': persona,
    'groups': groups,
    'userCard': userCard,
    if (userAvatar != null) 'userAvatar': base64Encode(userAvatar!),
    'worlds': worlds.map((w) => w.toJson()).toList(),
    'stickerGroups': stickerGroups.map((g) => g.toJson()).toList(),
    'stickers': stickers.map((s) => s.toJson()).toList(),
    'useBeta': useBeta,
    'useAccount': useAccount,
  };

  Future<void> saveChats() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_archiveBlocked || !_ready || _disposed) return Future.value();
    _savePending = true;
    if (_archiveTransaction) return _writes;
    if (_saveRunning) return _writes;
    _saveRunning = true;
    _writes = _drainChatWrites();
    return _writes;
  }

  Future<void> _drainChatWrites() async {
    try {
      while (_savePending) {
        _savePending = false;
        try {
          final snapshot = await exportChatsAsync();
          await _storage.write(snapshot);
          if (storageError != null) {
            storageError = null;
            changed();
          }
        } catch (_) {
          storageError = '聊天记录未能保存，请检查设备存储空间。';
          changed();
        }
      }
    } finally {
      _saveRunning = false;
    }
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
    if (target.placeholder && text.trim().isNotEmpty) {
      target.placeholder = false;
      changed();
    }
    _saveSoon();
  }

  Future<void> clearChats() async {
    if (_archiveTransaction) throw StateError('聊天记录操作正在进行');
    _archiveTransaction = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final roleId = role.id;
      final fresh = Conversation(
        '新的对话',
        [],
        personaId: roleId,
        placeholder: true,
      );
      stop();
      await _writes;
      await _storage.clearArchive(
        jsonEncode({
          ...jsonDecode(exportChats()) as Map<String, dynamic>,
          'selected': 0,
          'selectedId': fresh.id,
          'conversations': [fresh.toJson()],
          'persona': personas.indexWhere((p) => p.id == roleId),
        }),
      );
      _archiveBlocked = false;
      storageError = null;
      conversations
        ..clear()
        ..add(fresh);
      conversation = 0;
      persona = personas.indexWhere((p) => p.id == roleId);
      changed();
    } catch (_) {
      _archiveBlocked = true;
      storageError = '清理未完成，请重试清空；已暂停自动保存。';
      rethrow;
    } finally {
      _archiveTransaction = false;
      if (_savePending) await saveChats();
    }
  }

  Future<void> importChats(String text) async {
    if (_archiveTransaction) throw StateError('聊天记录操作正在进行');
    _archiveTransaction = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final raw = _normalizeArchive(jsonDecode(text) as Map<String, dynamic>);
      if (raw['schema'] != 'skivu-chats-v1') throw const FormatException();
      final loaded = (raw['conversations'] as List)
          .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c)))
          .toList();
      final roles = (raw['personas'] as List?)
          ?.map((p) => Persona.fromJson(Map<String, dynamic>.from(p)))
          .toList();
      stop();
      await _writes;
      if (!_archiveBlocked) await _storage.write(await exportChatsAsync());
      await _storage.replaceArchive(await compute(jsonEncode, raw));
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
      roleFolders
        ..clear()
        ..addAll(Map<String, bool>.from(raw['roleFolders'] as Map));
      if (raw['userCard'] is Map)
        userCard = {
          for (final e in (raw['userCard'] as Map).entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        };
      userAvatar = Persona._readAvatar(raw['userAvatar']);
      _restoreLibraries(raw);
      if (raw['groups'] is List) {
        groups
          ..clear()
          ..addAll((raw['groups'] as List).whereType<String>().toSet());
        if (!groups.contains('全部')) groups.insert(0, '全部');
      }
      _archiveBlocked = false;
      storageError = null;
      changed();
    } finally {
      _archiveTransaction = false;
      if (_savePending) await saveChats();
    }
  }

  void newChat({String? personaId}) {
    final selectedRole = personas
        .where((p) => p.id == (personaId ?? role.id))
        .firstOrNull;
    if (selectedRole == null) return;
    stop();
    conversations.removeWhere(
      (c) => c.placeholder && c.messages.isEmpty && c.draft.isEmpty,
    );
    conversations.insert(
      0,
      Conversation('新的对话', [
        if ((selectedRole.card['开场白'] ?? '').trim().isNotEmpty)
          Message(false, selectedRole.card['开场白']!),
      ], personaId: selectedRole.id),
    );
    conversation = 0;
    persona = personas.indexOf(selectedRole);
    roleFolders[selectedRole.id] = true;
    changed();
    saveChats();
  }

  void selectChat(int index) {
    if (index < 0 || index >= conversations.length) return;
    stop();
    conversation = index;
    persona = personas.indexOf(role);
    roleFolders[role.id] = true;
    changed();
    saveChats();
  }

  void renameChat(String id, String title) {
    final chat = conversations.where((c) => c.id == id).firstOrNull;
    if (chat == null || title.trim().isEmpty) return;
    chat.title = title.trim().characters.take(80).join();
    chat.titleEdited = true;
    changed();
    saveChats();
  }

  void toggleChatPin(String id) {
    final chat = conversations.where((c) => c.id == id).firstOrNull;
    if (chat == null) return;
    chat.pinned = !chat.pinned;
    changed();
    saveChats();
  }

  ClearedChatMessages? clearChatMessages(String id) {
    final target = conversations.where((c) => c.id == id).firstOrNull;
    if (target == null) return null;
    if (identical(target, conversations[conversation])) stop();
    final backup = ClearedChatMessages(target);
    target.messages.clear();
    target.interactions.clear();
    target.interactionsClearedAt = DateTime.now();
    target.usedTokens = 0;
    target.usage = const ConversationUsage();
    target.placeholder = false;
    changed();
    saveChats();
    return backup;
  }

  bool restoreClearedMessages(ClearedChatMessages backup) {
    if (backup.restored || !conversations.contains(backup.chat)) return false;
    final target = backup.chat;
    if (target.messages.isEmpty) target.usage = backup.usage;
    target.messages.insertAll(0, backup.messages);
    target.interactions.insertAll(0, backup.interactions);
    target.interactionsClearedAt = backup.clearedAt;
    target.usedTokens += backup.usedTokens;
    backup.restored = true;
    changed();
    saveChats();
    return true;
  }

  void deleteChat(String id) {
    final chat = conversations.where((c) => c.id == id).firstOrNull;
    if (chat == null) return;
    final active = conversations[conversation];
    if (identical(active, chat)) stop();
    conversations.remove(chat);
    if (conversations.isEmpty)
      conversations.add(
        Conversation('新的对话', [], personaId: chat.personaId, placeholder: true),
      );
    final next = identical(active, chat)
        ? conversations
                  .where((c) => c.personaId == chat.personaId && !c.placeholder)
                  .firstOrNull ??
              conversations.first
        : active;
    conversation = conversations.indexOf(next);
    persona = personas.indexOf(role);
    changed();
    saveChats();
  }

  List<Message> roundMessages(String chatId, Message anchor) {
    final chat = conversations.where((c) => c.id == chatId).firstOrNull;
    if (chat == null) return const [];
    var start = chat.messages.indexOf(anchor);
    if (start < 0) return const [];
    if (anchor.status == 'queued') return [anchor];
    if (anchor.turnId != null)
      return chat.messages.where((m) => m.turnId == anchor.turnId).toList();
    while (start > 0 && !chat.messages[start].user) {
      start--;
    }
    var end = start + 1;
    while (end < chat.messages.length && !chat.messages[end].user) {
      end++;
    }
    return List.unmodifiable(chat.messages.sublist(start, end));
  }

  bool deleteRound(String chatId, Message anchor) {
    final chat = conversations.where((c) => c.id == chatId).firstOrNull;
    final round = roundMessages(chatId, anchor);
    if (chat == null || round.isEmpty) return false;
    if (round.contains(_pending)) stop();
    chat.messages.removeWhere(round.contains);
    changed();
    saveChats();
    return true;
  }

  void stop() {
    _reveal?.flush();
    _reveal?.dispose();
    _reveal = null;
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

  bool send(
    String input, {
    bool? streamingOverride,
    String kind = 'text',
    String? stickerId,
    bool immediate = false,
    String? imageData,
    bool described = false,
  }) {
    if (input.trim().isEmpty || streaming) return false;
    if (!['text', 'voice', 'photo', 'image', 'sticker'].contains(kind) ||
        (kind == 'image' && !validChatImage(imageData)) ||
        (kind == 'sticker' && stickerFor(stickerId)?.active != true))
      return false;
    final target = conversations[conversation];
    if (immediate && target.queuedMessages.isNotEmpty) {
      lastError = '请先确认或移除待发送消息。';
      changed();
      return false;
    }
    if (!immediate &&
        (target.confirmBeforeReply || target.queuedMessages.isNotEmpty)) {
      if (target.queuedMessages.length >= 20 ||
          target.queuedMessages.fold<int>(0, (n, m) => n + m.text.length) +
                  input.length >
              100000) {
        lastError = '最多暂存20条消息，请先确认发送。';
        changed();
        return false;
      }
      messages.add(
        Message(true, input.trim())
          ..kind = kind
          ..stickerId = stickerId
          ..imageData = imageData
          ..described = described
          ..status = 'queued',
      );
      target.placeholder = false;
      lastError = null;
      changed();
      saveChats();
      return true;
    }
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
    messages.add(
      Message(true, input.trim())
        ..kind = kind
        ..stickerId = stickerId
        ..imageData = imageData
        ..described = described
        ..turnId = _localId('turn'),
    );
    conversations[conversation].placeholder = false;
    if (!conversations[conversation].titleEdited &&
        messages.where((m) => m.user).length == 1)
      conversations[conversation].title = input.trim().length > 14
          ? input.trim().substring(0, 14)
          : input.trim();
    return _respond(config, input, streamingOverride: streamingOverride);
  }

  bool confirmPending({bool? streamingOverride}) {
    final target = conversations[conversation],
        queued = conversations[conversation].queuedMessages;
    if (streaming || queued.isEmpty) return false;
    final config = activeConnection;
    if (config == null) {
      lastError = '请先选择可用模型，待发送消息已保留。';
      changed();
      return false;
    }
    final turn = _localId('turn');
    for (final message in queued) {
      message.status = 'complete';
      message.turnId = turn;
    }
    if (!target.titleEdited &&
        target.messages.where((m) => m.user).length == queued.length) {
      target.title = queued.first.text.characters.take(14).join();
    }
    return _respond(
      config,
      queued.map((m) => m.text).join('\n'),
      streamingOverride: streamingOverride,
    );
  }

  void discardQueued() {
    conversations[conversation].messages.removeWhere(
      (m) => m.status == 'queued',
    );
    changed();
    saveChats();
  }

  bool _respond(
    ModelConnection config,
    String input, {
    bool? streamingOverride,
  }) {
    attached = false;
    final connection = streamingOverride == null
        ? config
        : config.withStreaming(streamingOverride);
    if (conversations[conversation].groupMembers.isNotEmpty) {
      final target = conversations[conversation];
      final members = target.groupMembers
          .map((id) => personas.where((p) => p.id == id).firstOrNull)
          .whereType<Persona>()
          .toList();
      final mentioned = members
          .where((p) => input.contains('@${p.name}'))
          .toList();
      final turn = (target.messages.where((m) => m.user).length - 1);
      final chosen = target.groupRule == 'mentions'
          ? mentioned
          : target.groupRule != 'roundRobin' && mentioned.isNotEmpty
          ? mentioned
          : target.groupRule == 'roundRobin' || target.groupRule == 'automatic'
          ? [
              for (
                var i = 0;
                i < target.groupMaxReplies && i < members.length;
                i++
              )
                members[(turn + i) % members.length],
            ]
          : members.take(1).toList();
      final selected = chosen.take(target.groupMaxReplies).toList();
      if (selected.isEmpty) {
        saveChats();
        changed();
        return true;
      }
      lastError = null;
      streaming = true;
      final generation = ++_generation;
      changed();
      unawaited(_beginGroup(target, connection, selected, generation));
    } else {
      _begin(connection);
    }
    return true;
  }

  Future<void> _beginGroup(
    Conversation target,
    ModelConnection config,
    List<Persona> members,
    int generation,
  ) async {
    final betaRequest = useBeta, accountRequest = useAccount && !useBeta;
    try {
      for (final member in members) {
        if (generation != _generation ||
            _disposed ||
            !conversations.contains(target))
          return;
        if (!personas.any((p) => p.id == member.id)) continue;
        final history = target.messages
            .where(
              (m) =>
                  m.status != 'queued' &&
                  (m.user || (m.text.isNotEmpty && m.status != 'failed')),
            )
            .toList();
        var historyStart = (history.length - target.groupHistoryLimit).clamp(
          0,
          history.length,
        );
        // A history preference must not split a user/assistant turn or queued media.
        while (historyStart > 0 &&
            (history[historyStart].user == false ||
                history[historyStart - 1].user)) {
          historyStart--;
        }
        final values = history
            .skip(historyStart)
            .map(
              (m) => {
                ...m.apiMessage,
                'content': m.user
                    ? m.modelText
                    : '${personas.where((p) => p.id == m.authorId).firstOrNull?.name ?? '群成员'}：${m.text}',
              },
            )
            .toList();
        final answer = Message(false, '')
          ..requestStreaming = config.streaming
          ..turnId = history.lastOrNull?.turnId
          ..authorId = member.id
          ..status = 'pending'
          ..modelName = config.model
          ..provider = config.provider;
        target.messages.add(answer);
        _pending = answer;
        streaming = true;
        final prompt =
            '${promptFor(member)}\n\n这是角色群聊“${target.title}”。你只以${member.name}身份回应，不代替用户或其他成员发言。'
                .replaceAll('{{char}}', member.name)
                .replaceAll('{{user}}', userCard['称呼'] ?? '用户');
        changed();
        await _generate(
          target,
          answer,
          config,
          values,
          prompt,
          generation,
          betaRequest,
          accountRequest,
          keepStreaming: true,
        );
        if (answer.status == 'failed') break;
      }
    } finally {
      if (generation == _generation) {
        streaming = false;
        _pending = null;
        _session = null;
        saveChats();
        changed();
      }
    }
  }

  void regenerate() {
    if (streaming ||
        activeConnection == null ||
        messages.isEmpty ||
        messages.last.user)
      return;
    final target = conversations[conversation];
    if (target.groupMembers.isNotEmpty) {
      final author = personas
          .where(
            (p) =>
                p.id == messages.last.authorId &&
                target.groupMembers.contains(p.id),
          )
          .firstOrNull;
      if (author == null) return;
      final requestStreaming = messages.last.requestStreaming;
      messages.removeLast();
      lastError = null;
      streaming = true;
      final generation = ++_generation;
      changed();
      unawaited(
        _beginGroup(
          target,
          requestStreaming == null
              ? activeConnection!
              : activeConnection!.withStreaming(requestStreaming),
          [author],
          generation,
        ),
      );
    } else {
      messages.removeLast();
      _begin(activeConnection!);
    }
  }

  /// A social job owns its own session and never appends to a chat or changes
  /// the selected role, conversation, draft, or connection configuration.
  Future<ChatSession> startSocialReply(
    String personaId,
    String instruction,
  ) async {
    final persona = personas.where((p) => p.id == personaId).firstOrNull;
    final active = activeConnection;
    if (persona == null) throw const ChatFailure('参与互动的角色已不存在。');
    if (active == null) throw const ChatFailure('请先在模型与服务中配置可用模型。');
    final config = ModelConnection.fromJson({
      ...active.toJson(),
      'streaming': false,
      'maxOutput': active.maxOutput.clamp(16, 512),
    });
    final prompt = promptFor(persona)
        .replaceAll('{{char}}', persona.name)
        .replaceAll('{{user}}', userCard['称呼'] ?? '用户');
    final history = [
      {'role': 'user', 'content': instruction},
    ];
    if (useBeta) return beta.startChat(history, prompt, requestConfig: config);
    if (useAccount)
      return account.startChat(history, prompt, requestConfig: config);
    final key = await models.keyFor(config.id);
    if (key.isEmpty &&
        config.auth != 'none' &&
        !['Ollama', 'LM Studio'].contains(config.provider)) {
      throw const ChatFailure('此连接未填写 API Key，请在模型设置中补充。');
    }
    return _api.start(config, key, history, prompt);
  }

  void _begin(ModelConnection config) {
    lastError = null;
    final target = conversations[conversation];
    final history = messages
        .where(
          (m) =>
              m.status != 'queued' &&
              (m.user || (m.text.isNotEmpty && m.status != 'failed')),
        )
        .map((m) => m.apiMessage)
        .toList();
    final answer = Message(false, '')
      ..turnId = target.messages.lastOrNull?.turnId
      ..status = 'pending'
      ..modelName = config.model
      ..provider = config.provider;
    messages.add(answer);
    _pending = answer;
    streaming = true;
    final generation = ++_generation;
    final prompt =
        [
              promptFor(role),
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
    bool accountRequest, {
    bool keepStreaming = false,
  }) async {
    final watch = Stopwatch()..start();
    var usage = const ApiUsage();
    final reveal = StreamReveal((text, thinking) {
      if (generation != _generation) return;
      answer.text += text;
      if (thinking.isNotEmpty)
        answer.thinking = '${answer.thinking ?? ''}$thinking';
      _saveSoon();
      changed();
    });
    _reveal = reveal;
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
          ? beta.startChat(history, prompt, streaming: config.streaming)
          : accountRequest
          ? account.startChat(history, prompt, streaming: config.streaming)
          : _api.start(config, key, history, prompt);
      _session = session;
      await for (final event in session.events) {
        if (generation != _generation) return;
        if (config.streaming) {
          reveal.add(event.text, event.thinking);
        } else {
          answer.text += event.text;
          if (event.thinking.isNotEmpty)
            answer.thinking = '${answer.thinking ?? ''}${event.thinking}';
        }
        if (event.notice != null) answer.contextNotice = event.notice;
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
        if (!config.streaming || event.usage != null) changed();
      }
      watch.stop();
      await reveal.finish();
      if (generation != _generation) return;
      if (answer.text.trim().isEmpty)
        throw const ChatFailure('服务没有返回文字回复，请检查模型、输出上限或重试。');
      answer.status = 'complete';
      answer.unread =
          !(_chatForeground && _chatReaders.containsValue(target.id));
    } catch (e) {
      if (generation != _generation) return;
      reveal.flush();
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
      reveal.dispose();
      if (identical(_reveal, reveal)) _reveal = null;
      if (accountRequest && account.signedIn) unawaited(account.refresh());
      watch.stop();
      if (generation == _generation) {
        answer.elapsedMs = watch.elapsedMilliseconds;
        if (usage.input != null && usage.output != null)
          target.usedTokens += usage.input! + usage.output!;
        streaming = keepStreaming;
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
    _reveal?.dispose();
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
