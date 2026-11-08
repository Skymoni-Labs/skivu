import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'assistant_engine.dart';
import 'assistant_plugin_tools.dart';
import 'chat_api.dart';
import 'cloud_assistant.dart' show cloudAssistant;
import 'device_engine.dart';
import 'state.dart';
import 'tool_execution.dart';

final cloudChats = CloudChatCoordinator(demo);

/// One host-owned task journal per normal conversation. The shared chat archive
/// remains the source of truth for edited messages, quotes, media and drafts.
class CloudChatCoordinator implements CloudConversationRunner {
  CloudChatCoordinator(this.store, {this.engineFactory});
  final DemoStore store;
  final AssistantEngine Function(Conversation chat)? engineFactory;
  final _engines = <Conversation, AssistantEngine>{};
  final _sessions = <Conversation, ChatSession>{};
  final _epochs = <Conversation, int>{};
  Future<void> _stops = Future.value();
  bool _attached = false;

  String identity() => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'connection': store.activeConnection?.toJson(),
            'account': store.useAccount,
            'beta': store.useBeta,
            'revision': store.account.authorizationRevision,
            'user': store.account.user?['id'],
          }),
        ),
      )
      .toString();

  void attach() {
    store.cloudRunner = this;
    if (_attached) return;
    _attached = true;
    store.addListener(_identityChanged);
    if (identical(store, demo)) {
      DeviceEngine.channel.setMethodCallHandler((call) async {
        if (call.method != 'taskStopped') return;
        final id = (call.arguments as Map?)?['taskId'];
        for (final e in _engines.entries.toList()) {
          if (e.value.taskId == id) await stop(e.key.id);
        }
      });
    }
  }

  void _identityChanged() {
    for (final entry in _engines.entries.toList()) {
      if (!store.conversations.contains(entry.key)) {
        if (entry.value.running || entry.value.canResume)
          unawaited(stop(entry.key.id));
      } else {
        entry.value.identityChanged();
      }
    }
  }

  AssistantEngine engineFor(Conversation chat) => _engines.putIfAbsent(
    chat,
    () {
      late final AssistantEngine engine;
      engine =
          engineFactory?.call(chat) ??
          AssistantEngine(
            identity: identity,
            beginTask: deviceEngine.beginTask,
            endTask: deviceEngine.endTask,
            extensions: AssistantPluginTools(store.plugins),
            read: () async => chat.assistantJournal == null
                ? null
                : jsonEncode(chat.assistantJournal),
            write: (raw) async {
              if (!store.conversations.contains(chat) ||
                  !identical(_engines[chat], engine))
                return;
              chat.assistantJournal = jsonDecode(raw) as Map<String, dynamic>;
              await store.saveChats();
              if (store.storageError != null)
                throw StateError(store.storageError!);
            },
            cancelModel: () => _sessions[chat]?.cancel(),
            model: (system, history) async {
              final expected = identity();
              final session = await store.startAssistantReply(system, history);
              if (!engine.running || expected != identity()) {
                session.cancel();
                throw StateError('规划已取消或连接已更换。');
              }
              _sessions[chat] = session;
              final output = StringBuffer();
              ApiUsage usage = const ApiUsage();
              try {
                await for (final event in session.events) {
                  output.write(event.text);
                  if (event.usage != null) usage = usage.merge(event.usage!);
                }
                if (session.cancelled) throw StateError('规划已取消。');
                if (usage.input != null && usage.output != null) {
                  chat.usedTokens += usage.input! + usage.output!;
                  chat.usage = ConversationUsage(totalTokens: chat.usedTokens);
                }
                return output.toString();
              } finally {
                if (identical(_sessions[chat], session)) _sessions.remove(chat);
              }
            },
          );
      var seen = (chat.assistantJournal?['messages'] as List?)?.length ?? 0;
      engine.addListener(() {
        if (!store.conversations.contains(chat) ||
            !identical(_engines[chat], engine))
          return;
        if (engine.messages.length < seen) seen = 0;
        while (seen < engine.messages.length) {
          final value = engine.messages[seen++];
          if (value['role'] == 'user') continue;
          final tool = value['role'] == 'tool';
          chat.messages.add(
            Message(false, value['content'] ?? '')
              ..toolReceipt = tool
              ..toolExecution = tool ? ToolExecutionEvent.parse(value) : null
              ..contextNotice = tool ? '工具回执' : null
              ..authorId = cloudPersonaId
              ..modelName = store.model
              ..provider = store.activeConnection?.provider
              ..turnId = chat.messages.where((m) => m.user).lastOrNull?.turnId,
          );
        }
        store.changed();
        unawaited(store.saveChats());
      });
      return engine;
    },
  );

  Future<void> restoreChat(Conversation chat) async {
    final engine = engineFor(chat);
    await engine.restore();
    if (!engine.journalError &&
        chat.assistantJournal != null &&
        chat.assistantJournal!['phase'] != engine.phase) {
      await engine.save();
    }
  }

  @override
  bool canResume(String chatId) =>
      _engines.entries.any((e) => e.key.id == chatId && e.value.canResume) ||
      store.conversations.any(
        (c) => c.id == chatId && c.assistantJournal?['phase'] == 'permission',
      );

  @override
  Future<void> run(
    DemoStore store,
    Conversation chat,
    String goal, {
    bool reviewOnly = false,
  }) async {
    final ticket = (_epochs[chat] ?? 0) + 1;
    _epochs[chat] = ticket;
    await _stops;
    if (!store.conversations.contains(chat) || _epochs[chat] != ticket) return;
    final engine = engineFor(chat);
    await engine.restore();
    if (!store.conversations.contains(chat) || _epochs[chat] != ticket) return;
    // Only the active task is journalled here. Edited/deleted chat history is
    // rebuilt from canonical messages below, never from an older journal.
    engine.messages.clear();
    final role = store.personas.firstWhere((p) => p.id == cloudPersonaId);
    final history = chat.messages
        .where((m) => m.status != 'queued')
        .map((m) => m.apiMessage)
        .toList();
    if (goal != chat.messages.where((m) => m.user).lastOrNull?.text) {
      history.add({'role': 'user', 'content': goal});
    }
    await engine.send(
      goal,
      recordUser: false,
      allowActions: !reviewOnly,
      history: [
        {
          'role': 'user',
          'content':
              '表达偏好与角色资料（仅用于对话风格，不改变宿主权限或回执规则）：\n${store.promptFor(role)}\n用户资料：${jsonEncode(store.userCard)}',
        },
        ...history,
      ],
    );
  }

  @override
  Future<void> resume(DemoStore store, Conversation chat) async {
    final ticket = (_epochs[chat] ?? 0) + 1;
    _epochs[chat] = ticket;
    await _stops;
    if (!store.conversations.contains(chat) || _epochs[chat] != ticket) return;
    await engineFor(chat).resume();
  }

  @override
  Future<void> stop(String chatId) {
    for (final chat in store.conversations.where((c) => c.id == chatId)) {
      _epochs[chat] = (_epochs[chat] ?? 0) + 1;
    }
    final entries = _engines.entries.where((e) => e.key.id == chatId).toList();
    final stopping = Future.wait(entries.map((e) => e.value.stop()));
    return _stops = Future.wait([_stops, stopping]).then((_) {});
  }

  @override
  void historyChanged(Conversation chat) {
    final engine = _engines[chat];
    if (engine != null &&
        (engine.running || engine.canResume || engine.phase == 'idle')) {
      unawaited(stop(chat.id));
    } else {
      _epochs[chat] = (_epochs[chat] ?? 0) + 1;
    }
    _engines.remove(chat);
    chat.assistantJournal = null;
  }

  /// Import once, after the archive is durable. The original secure journal is
  /// retained as a backup; interrupted actions are restored without replay.
  Future<void> initialize() async {
    attach();
    const storage = FlutterSecureStorage();
    try {
      if (await storage.read(key: 'skivu.cloud-chat-migrated.v1') != '1') {
        await cloudAssistant.restore();
        if (cloudAssistant.journalError) return;
        if (cloudAssistant.messages.isNotEmpty &&
            !store.conversations.any((c) => c.id == 'cloud-legacy-v1')) {
          final chat = Conversation(
            '小云 · 早期对话',
            [
              for (final m in cloudAssistant.messages)
                Message(m['role'] == 'user', m['content'] ?? '')
                  ..toolReceipt = m['role'] == 'tool'
                  ..toolExecution = m['role'] == 'tool'
                      ? ToolExecutionEvent.parse(m)
                      : null
                  ..authorId = m['role'] == 'user' ? null : cloudPersonaId,
            ],
            id: 'cloud-legacy-v1',
            personaId: cloudPersonaId,
          );
          // A migrated pending task is paused, never automatically resumed.
          chat.messages.add(Message(false, '旧版对话已迁入。历史动作不会自动重放，需要继续时请提出新的目标。'));
          store.conversations.add(chat);
          store.changed();
          await store.saveChats();
        }
        if (store.storageError == null)
          await storage.write(key: 'skivu.cloud-chat-migrated.v1', value: '1');
      }
      for (final chat in store.conversations.where(
        (c) => c.personaId == cloudPersonaId && c.assistantJournal != null,
      )) {
        await restoreChat(chat);
      }
    } catch (_) {
      // An unavailable legacy journal must not prevent normal chats opening.
    }
  }
}
