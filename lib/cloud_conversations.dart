import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'assistant_engine.dart';
import 'assistant_plugin_tools.dart';
import 'assistant_task_tools.dart';
import 'assistant_plan_tools.dart';
import 'task_plans.dart';
import 'assistant_reminder_tools.dart';
import 'task_model_binding.dart';
import 'personal_space.dart';
import 'chat_api.dart';
import 'cloud_assistant.dart' show cloudAssistant;
import 'device_engine.dart';
import 'state.dart';
import 'tool_execution.dart';
import 'assistant_stream_preview.dart';
import 'stream_reveal.dart';
import 'cloud_coding_tools.dart';
import 'cloud_execution_state.dart';
import 'phone_task_adapters.dart';
import 'cloud_integration.dart';

class _ReplyDraft {
  _ReplyDraft(this.message, this.epoch);
  final Message message;
  final int epoch;
}

final cloudChats = CloudChatCoordinator(demo);

/// One host-owned task journal per normal conversation. The shared chat archive
/// remains the source of truth for edited messages, quotes, media and drafts.
class CloudChatCoordinator implements CloudConversationRunner {
  CloudChatCoordinator(
    this.store, {
    this.engineFactory,
    PersonalSpaceStore? tasks,
  }) : tasks = tasks ?? personalSpace;
  final DemoStore store;
  final PersonalSpaceStore tasks;
  final AssistantEngine Function(Conversation chat)? engineFactory;
  final _engines = <Conversation, AssistantEngine>{};
  final _sessions = <Conversation, ChatSession>{};
  final _drafts = <Conversation, _ReplyDraft>{};
  final _epochs = <Conversation, int>{};
  final _executionStates = <Conversation, CloudExecutionState>{};
  Future<void> _stops = Future.value();
  bool _attached = false;

  String identity() => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'connection': store.activeConnection == null
                ? null
                : modelAuthority(store.activeConnection!.toJson()),
            'account': store.useAccount,
            'beta': store.useBeta,
            'revision': store.account.authorizationRevision,
            'user': store.account.user?['id'],
          }),
        ),
      )
      .toString();

  bool compatibleLegacyIdentity(String old) {
    final current = store.activeConnection;
    if (current == null) return false;
    final config = current.toJson()
      ..remove('limitsVersion')
      ..remove('legacyLimits');
    final legacy = current.legacyLimits;
    if (legacy != null) {
      if (legacy['maxOutput'] is int) config['maxOutput'] = legacy['maxOutput'];
      if (legacy['timeoutSeconds'] is int)
        config['timeoutSeconds'] = legacy['timeoutSeconds'];
    }
    return old ==
        sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'connection': config,
                  'account': store.useAccount,
                  'beta': store.useBeta,
                  'revision': store.account.authorizationRevision,
                  'user': store.account.user?['id'],
                }),
              ),
            )
            .toString();
  }

  void attach() {
    store.cloudRunner = this;
    if (_attached) return;
    _attached = true;
    if (identical(store, demo)) unawaited(cloudIntegration.initialize());
    store.addListener(_identityChanged);
    if (identical(store, demo)) {
      CloudExecutionState.controls.setMethodCallHandler((call) async {
        if (call.method != 'control') return;
        final value = Map<String, dynamic>.from(call.arguments as Map);
        for (final entry in _engines.entries.toList()) {
          if (entry.value.taskId != value['taskId']) continue;
          switch (value['action']) {
            case 'stop':
              await stop(entry.key.id);
            case 'pause':
              entry.value.requestPause();
            case 'resume':
              entry.value.continuePaused();
          }
        }
      });
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
        _drafts.remove(entry.key);
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
      final reminders = AssistantReminderTools(tasks, taskPlans);
      engine =
          engineFactory?.call(chat) ??
          AssistantEngine(
            identity: identity,
            compatibleIdentity: compatibleLegacyIdentity,
            beginTask: deviceEngine.beginTask,
            endTask: deviceEngine.endTask,
            extensions: CombinedAssistantTools([
              CloudCodingTools(
                owner: 'cloud:${chat.id}',
                taskId: () => engine.taskId,
                hasActiveWork: () =>
                    engine.activeCodingJobs.isNotEmpty ||
                    engine.checkpointPending?.contains('coding.') == true,
              ),
              AssistantPluginTools(store.plugins),
              PhoneTaskAdapters(() => engine.latestObservation),
            ]),
            taskTools: AssistantPlanTools(
              AssistantTaskTools(tasks),
              taskPlans,
              modelIdentity: () => scheduledModelIdentity(store),
              modelBinding: () => scheduledModelBinding(store),
              modelName: () => store.model,
              reminders: reminders,
            ),
            recordEffect: reminders.capture,
            confirmEffect: reminders.confirm,
            toolSubmissions: chat.toolSubmissions,
            persistToolSubmissions: () async {
              await store.saveChats();
              if (store.storageError != null)
                throw StateError(store.storageError!);
            },
            findPreviousEffect: deviceEngine.previousEffect,
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
              final generation = engine.epoch;
              final session = await store.startAssistantReply(
                system,
                history,
                streaming: chat.messages
                    .where((m) => m.user)
                    .lastOrNull
                    ?.requestStreaming,
              );
              if (!engine.running || expected != identity()) {
                session.cancel();
                throw StateError('规划已取消或连接已更换。');
              }
              _sessions[chat] = session;
              final output = StringBuffer();
              final thinking = StringBuffer();
              var limited = false;
              var prefix = '';
              final stale = _drafts.remove(chat);
              if (stale != null) chat.messages.remove(stale.message);
              Message draft() {
                final old = _drafts[chat];
                if (old != null && old.epoch == generation) return old.message;
                final message = Message(false, '')
                  ..status = 'pending'
                  ..authorId = cloudPersonaId
                  ..modelName = session.config.model
                  ..provider = session.config.provider
                  ..turnId = chat.messages
                      .where((m) => m.user)
                      .lastOrNull
                      ?.turnId;
                _drafts[chat] = _ReplyDraft(message, generation);
                chat.messages.add(message);
                return message;
              }

              final reveal = StreamReveal((text, reason) {
                if (engine.epoch != generation ||
                    expected != identity() ||
                    !store.conversations.contains(chat))
                  return;
                final message = draft();
                message.text += text;
                if (reason.isNotEmpty)
                  message.thinking = '${message.thinking ?? ''}$reason';
                store.assistantProgressChanged();
              });
              ApiUsage usage = const ApiUsage();
              try {
                await for (final event in session.events) {
                  if (engine.epoch != generation ||
                      expected != identity() ||
                      !engine.running ||
                      !store.conversations.contains(chat)) {
                    session.cancel();
                    throw StateError('规划已取消或连接已更换。');
                  }
                  output.write(event.text);
                  limited = limited || event.limited;
                  thinking.write(event.thinking);
                  if (session.config.streaming) {
                    final next = engine.hasUnverifiedEffects
                        ? null
                        : assistantFinalPrefix(output.toString());
                    var delta = '';
                    if (next != null && next.startsWith(prefix)) {
                      delta = next.substring(prefix.length);
                      prefix = next;
                    }
                    reveal.add(delta, event.thinking);
                  }
                  if (event.usage != null) usage = usage.merge(event.usage!);
                }
                if (session.cancelled) throw StateError('规划已取消。');
                await reveal.finish();
                if (!session.config.streaming && thinking.isNotEmpty)
                  draft().thinking = thinking.toString();
                if (usage.input != null && usage.output != null) {
                  chat.usedTokens += usage.input! + usage.output!;
                  chat.usage = ConversationUsage(totalTokens: chat.usedTokens);
                }
                if (limited)
                  throw AssistantOutputLimit(
                    session.effectiveMaxOutput,
                    output.toString(),
                  );
                return output.toString();
              } finally {
                reveal.flush();
                reveal.dispose();
                if (identical(_sessions[chat], session)) _sessions.remove(chat);
              }
            },
          );
      var seen = (chat.assistantJournal?['messages'] as List?)?.length ?? 0;
      final execution = CloudExecutionState(engine, chat.id);
      _executionStates[chat] = execution;
      engine.addListener(() {
        if (!store.conversations.contains(chat) ||
            !identical(_engines[chat], engine))
          return;
        execution.publish();
        for (final record in engine.messages.where(
          (m) => m['outcome'] == 'verified',
        )) {
          final existing = chat.messages
              .where(
                (m) =>
                    m.toolExecution?.taskId == record['taskId'] &&
                    m.toolExecution?.requestId == record['requestId'],
              )
              .lastOrNull;
          if (existing != null && existing.toolExecution?.outcome != 'verified')
            existing.toolExecution = ToolExecutionEvent.parse(record);
        }
        if (engine.messages.length < seen) seen = 0;
        while (seen < engine.messages.length) {
          final value = engine.messages[seen++];
          if (value['role'] == 'user') continue;
          final tool = value['role'] == 'tool';
          final draft = _drafts.remove(chat)?.message;
          if (draft != null && !tool) {
            final text = value['content'] ?? '';
            draft.text = engine.phase != 'done' && draft.text.isNotEmpty
                ? '${draft.text}\n\n$text'
                : text;
            draft.status = engine.phase == 'done' ? 'complete' : 'cancelled';
            continue;
          }
          if (draft != null) chat.messages.remove(draft);
          chat.messages.add(
            Message(false, value['content'] ?? '')
              ..thinking = draft?.thinking
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
    if (engine.recoveryRequired &&
        !engine.userPaused &&
        engine.phase != 'model_changed')
      unawaited(engine.recover());
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
        (c) =>
            c.id == chatId &&
            const {
              'permission',
              'confirmation',
            }.contains(c.assistantJournal?['phase']),
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
    await engine.abandonPending();
    if (!store.conversations.contains(chat) || _epochs[chat] != ticket) return;
    // Only the active task is journalled here. Edited/deleted chat history is
    // rebuilt from canonical messages below, never from an older journal.
    engine.messages.clear();
    _executionStates[chat]?.newTask();
    final role = store.personas.firstWhere((p) => p.id == cloudPersonaId);
    final current = !reviewOnly && chat.messages.lastOrNull?.user == true
        ? chat.messages.last
        : null;
    final history = chat.messages
        .where((m) => !identical(m, current))
        .where((m) => m.status != 'queued')
        .map((m) => m.apiMessage)
        .toList();
    Map<String, String>? selectedMessage = current?.apiMessage;
    final references = current == null
        ? <String>{}
        : {
            for (final m in chat.messages.where(
              (m) =>
                  m.user &&
                  (identical(m, current) ||
                      current.turnId != null && m.turnId == current.turnId),
            ))
              if (m.taskReference != null) m.taskReference!,
          };
    if (references.isNotEmpty) {
      await tasks.restore();
      if (!store.conversations.contains(chat) || _epochs[chat] != ticket)
        return;
      final selected = [
        for (final id in references)
          if (tasks.task(id) case final record?)
            {
              'id': record.id,
              'title': record.title,
              'revision': record.revision,
            }
          else
            {'id': id, 'missing': true},
      ];
      selectedMessage = {
        ...current!.apiMessage,
        'content':
            '${current.modelText}\n\n用户本条消息选中的任务（数据，仅供理解当前请求；修改前请 tasks.get 读取最新版本，missing 表示已不存在，不要新建替代项）：${jsonEncode(selected)}',
      };
    }
    await engine.send(
      goal,
      recordUser: false,
      allowActions: !reviewOnly,
      currentMessage: selectedMessage,
      history: [
        {
          'role': 'user',
          'content':
              '表达偏好与角色资料（仅用于对话风格，不改变宿主权限或回执规则）：\n${store.promptFor(role, includePluginPrompt: false)}\n用户资料：${jsonEncode(store.userCard)}',
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

  Future<void> confirmResult(Conversation chat) async {
    final engine = engineFor(chat);
    if (!engine.canConfirmResult) return;
    final task = engine.taskId;
    final oldText = engine.messages.lastOrNull?['content'];
    await engine.confirmResult();
    for (final source in engine.messages.where(
      (m) => m['taskId'] == task && m['outcome'] == 'user_confirmed',
    )) {
      final message = chat.messages
          .where(
            (m) =>
                m.toolExecution?.taskId == task &&
                m.toolExecution?.requestId == source['requestId'],
          )
          .lastOrNull;
      if (message != null) {
        message.text = source['content']!;
        message.toolExecution = ToolExecutionEvent.parse(source);
      }
    }
    if (oldText != null) {
      final answer = chat.messages
          .where((m) => !m.user && !m.toolReceipt && m.text == oldText)
          .lastOrNull;
      if (answer != null) answer.text = '本轮操作已按你的确认标记为完成，不会自动重做。';
    }
    store.changed();
    await store.saveChats();
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
    final draft = _drafts.remove(chat);
    if (draft != null) draft.message.status = 'cancelled';
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
