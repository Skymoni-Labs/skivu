import 'dart:convert';
import 'package:characters/characters.dart';
import 'state.dart';
import 'ui_plugins.dart';
import 'chat_interaction.dart';

/// Allowlisted projection of the original store. API credentials and role
/// prompts never cross the presentation boundary.
class UiHostBinding {
  UiHostBinding(this.store);
  final DemoStore store;
  final Map<String, int> draftRevisions = {};
  String? _lastChat, _rolesSignature;
  Object? _lastUserAvatar;
  int? _prefix, _count;
  Conversation get selected => store.conversations[store.conversation];
  Persona? roleFor(String id) =>
      store.personas.where((p) => p.id == id).firstOrNull;
  Message? messageFor(Map<String, dynamic> command) {
    if (!current(command)) return null;
    final index = command['index'];
    if (index is! int || index < 0 || index >= selected.messages.length)
      return null;
    final message = selected.messages[index];
    return message.created.toIso8601String() == command['created']
        ? message
        : null;
  }

  bool current(Map<String, dynamic> c) => c['chatId'] == selected.id;
  bool valid(Map<String, dynamic> c) =>
      c['protocol'] == 1 &&
      const {
        'ready',
        'draft',
        'send',
        'stop',
        'selectChat',
        'newChat',
        'renameRole',
        'editRole',
        'chatMenu',
        'messageMenu',
        'models',
        'settings',
        'call',
        'drawer',
        'userCard',
        'userAvatar',
        'roles',
        'userName',
        'socialSettings',
        'publishPost',
        'importPosts',
        'postAction',
        'favorites',
        'walletChange',
        'groupPreferences',
        'classicUi',
        'chatOptions',
        'clearChat',
        'chatAppearance',
        'chatInteraction',
        'hideInteraction',
        'walletInteraction',
        'createGroup',
        'groupConfig',
      }.contains(c['command']);

  String? mutate(
    Map<String, dynamic> c, {
    ChatUiMode mode = ChatUiMode.classic,
  }) {
    if (!valid(c)) return '不支持的界面请求';
    final action = c['command'];
    if ([
          'send',
          'stop',
          'messageMenu',
          'chatOptions',
          'clearChat',
          'chatInteraction',
          'hideInteraction',
          'walletInteraction',
          'groupConfig',
        ].contains(action) &&
        !current(c))
      return '当前对话已切换，请重试。';
    if (action == 'createGroup' || action == 'groupConfig') {
      final members = c['members'],
          title = c['title'],
          rule = c['rule'],
          limit = c['maxReplies'];
      if (members is! List ||
          members.length < 2 ||
          members.length > 8 ||
          members.any((id) => id is! String || roleFor(id) == null) ||
          members.toSet().length != members.length ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 60 ||
          !['manual', 'mentions', 'roundRobin', 'automatic'].contains(rule) ||
          limit is! int ||
          limit < 1 ||
          limit > 6)
        return '请填写群名称并选择 2—8 位角色。';
      if (action == 'createGroup') store.newChat(personaId: members.first);
      selected.groupMembers = members.cast<String>();
      selected.personaId = selected.groupMembers.first;
      selected.groupRule = rule;
      selected.groupKind = c['kind'] == 'channel' ? 'channel' : 'group';
      selected.groupMaxReplies = limit;
      selected.title = title.trim();
      selected.titleEdited = true;
      selected.placeholder = false;
      store.changed();
      store.saveChats();
      return null;
    }
    if (action == 'chatInteraction') {
      final raw = c['event'];
      final event = raw is Map ? cleanChatInteraction(raw) : null;
      if (event == null) return '附件格式不正确或超过 2MB。';
      if (event['kind'] == 'contact' &&
          roleFor(event['payload']['roleId']) == null)
        return '角色已不存在。';
      if (selected.interactions.any((e) => e['id'] == event['id'])) return null;
      if (selected.interactions.length >= 100 ||
          jsonEncode(selected.interactions).length + jsonEncode(event).length >
              12000000)
        return '此段对话附件已达本机上限，请先导出保存。';
      selected.interactions.add(event);
      selected.placeholder = false;
      store.changed();
      store.saveChats();
      return null;
    }
    if (action == 'hideInteraction') {
      final id = c['id'];
      if (id is! String || id.length > 100) return '消息标识不正确。';
      selected.hiddenInteractions.add(id);
      selected.interactions.removeWhere((e) => e['id'] == id);
      store.changed();
      store.saveChats();
      return null;
    }
    if (action == 'chatOptions') {
      final key = c['key'], value = c['value'];
      if (value is! bool) return '聊天设置格式不正确。';
      switch (key) {
        case 'pinned':
          selected.pinned = value;
        case 'muted':
          selected.muted = value;
        case 'replyReminder':
          selected.replyReminder = value;
        default:
          return '不支持的聊天设置。';
      }
      store.changed();
      store.saveChats();
      return null;
    }
    if (action == 'selectChat') {
      final index = store.conversations.indexWhere((v) => v.id == c['id']);
      if (index < 0) return '这段对话已不存在';
      if (index != store.conversation) store.selectChat(index);
      return null;
    }
    if (action == 'newChat') {
      final id = c['roleId'];
      if (id is! String || roleFor(id) == null) return '角色已不存在';
      store.newChat(personaId: id);
      return null;
    }
    if (action == 'draft' || action == 'send') {
      final target = action == 'draft'
          ? store.conversations.where((v) => v.id == c['chatId']).firstOrNull
          : selected;
      if (target == null) return '这段对话已不存在';
      final text = c['text'], revision = c['revision'];
      if (text is! String ||
          text.length > 10000 ||
          revision is! int ||
          revision < 0)
        return '消息格式不正确';
      if (revision <= (draftRevisions[target.id] ?? -1)) return null;
      draftRevisions[target.id] = revision;
      if (action == 'draft') {
        store.saveDraft(target, text);
        return null;
      }
      if (text.trim().isEmpty) return '请先输入消息';
      if (store.streaming) return '当前回复正在生成';
      if (!store.send(
        text,
        streamingOverride: mode == ChatUiMode.classic ? null : false,
      )) {
        return store.lastError ?? '请先配置模型连接';
      }
      store.saveDraft(selected, '');
      return null;
    }
    if (action == 'stop') {
      store.stop();
      return null;
    }
    if (action == 'renameRole') {
      final id = c['roleId'], name = c['name'];
      final role = id is String ? roleFor(id) : null;
      if (role == null ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 80)
        return '角色名称不正确';
      role.name = name.trim();
      store.changed();
      store.saveChats();
    }
    if (action == 'userName') {
      final name = c['name'];
      if (name is! String || name.trim().isEmpty || name.length > 80)
        return '名字不正确';
      store.userCard['称呼'] = name.trim();
      store.changed();
      store.saveChats();
    }
    return null;
  }

  Map<String, dynamic> _message(Message m, int index) => {
    'id': '${m.created.microsecondsSinceEpoch}-$index',
    'role': m.user ? 'user' : 'assistant',
    'text': m.text.isNotEmpty
        ? m.text
        : m.error ?? (m.status == 'pending' ? '正在思考…' : '未收到回复'),
    'thought': m.thinking,
    'authorId': m.authorId,
    'created': m.created.toIso8601String(),
    'time':
        '${m.created.hour.toString().padLeft(2, '0')}:${m.created.minute.toString().padLeft(2, '0')}',
  };

  Map<String, dynamic> snapshot(
    ChatUiMode mode, {
    bool force = false,
    String? view,
  }) {
    final chat = selected;
    final changed = _lastChat != chat.id;
    // Social modes show typing in the title, then one complete reply. Even a
    // provider that ignores stream:false cannot leak partial bubbles here.
    final values =
        mode != ChatUiMode.classic &&
            store.streaming &&
            chat.messages.lastOrNull?.status == 'pending'
        ? chat.messages.take(chat.messages.length - 1).toList()
        : chat.messages;
    final prefix = Object.hashAll(
      values
          .take(values.isEmpty ? 0 : values.length - 1)
          .map(
            (m) => Object.hash(m, m.text, m.thinking, m.bookmarked, m.status),
          ),
    );
    final delta =
        !force &&
        values.isNotEmpty &&
        _lastChat == chat.id &&
        _count == values.length &&
        _prefix == prefix;
    final signature = store.personas
        .map(
          (p) =>
              '${p.id}|${p.name}|${p.subtitle}|${p.icon.codePoint}|${p.color.toARGB32()}|${identityHashCode(p.avatar)}',
        )
        .join('\n');
    final fullRoles = force || signature != _rolesSignature;
    final userAvatarChanged =
        force || !identical(_lastUserAvatar, store.userAvatar);
    _lastUserAvatar = store.userAvatar;
    _lastChat = chat.id;
    _count = values.length;
    _prefix = prefix;
    _rolesSignature = signature;
    return {
      'protocol': 1,
      'mode': mode == ChatUiMode.qq ? 'qq' : 'wx',
      'selectedId': chat.id,
      'selectedRoleId': chat.personaId,
      'chatInfo': {
        'id': chat.id,
        'pinned': chat.pinned,
        'muted': chat.muted,
        'replyReminder': chat.replyReminder,
        'groupMembers': chat.groupMembers,
        'title': chat.title,
        'groupRule': chat.groupRule,
        'groupKind': chat.groupKind,
        'groupMaxReplies': chat.groupMaxReplies,
      },
      'streaming': store.streaming,
      'model': store.model,
      'draft': chat.draft,
      'draftRevision': draftRevisions[chat.id] ?? 0,
      'userLabel': store.userCard['称呼'] ?? '我',
      if (userAvatarChanged)
        'userAvatar': store.userAvatar == null
            ? null
            : 'data:image/png;base64,${base64Encode(store.userAvatar!)}',
      if (force || changed) 'interactions': chat.interactions,
      'hiddenInteractions': chat.hiddenInteractions.toList(),
      'interactionsClearedAt': chat.interactionsClearedAt?.toIso8601String(),
      if (force || changed)
        'attachmentIndex': [
          for (final c in store.conversations)
            for (final e in c.interactions)
              if (!c.hiddenInteractions.contains(e['id']))
                {
                  'id': e['id'],
                  'kind': e['kind'],
                  'created': e['created'],
                  'chatId': c.id,
                  'roleId': c.personaId,
                  'name':
                      e['payload']['name'] ??
                      e['payload']['label'] ??
                      e['payload']['name'] ??
                      '消息',
                  'bytes': e['payload']['bytes'],
                },
        ],
      if (view != null) 'view': view,
      if (fullRoles)
        'roles': [
          for (final p in store.personas)
            {
              'id': p.id,
              'name': p.name,
              'bio': p.subtitle,
              'color':
                  '#${(p.color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}',
              'glyph': String.fromCharCode(p.icon.codePoint),
              if (p.avatar != null)
                'avatar': 'data:image/png;base64,${base64Encode(p.avatar!)}',
            },
        ],
      'chats': [
        for (final c in SocialChatBinding(store).inbox)
          {
            'id': c.id,
            'personaId': c.personaId,
            'title': c.title,
            'pinned': c.pinned,
            'muted': c.muted,
            'groupMembers': c.groupMembers,
            'groupKind': c.groupKind,
            'lastCreated':
                c.messages.lastOrNull?.created.toIso8601String() ?? '',
            'localEvent': c.interactions.isEmpty
                ? null
                : {
                    'kind': c.interactions.last['kind'],
                    'created': c.interactions.last['created'],
                  },
            'hiddenInteractions': c.hiddenInteractions.toList(),
            'interactionsClearedAt': c.interactionsClearedAt?.toIso8601String(),
            'preview':
                (c.draft.isNotEmpty
                        ? c.draft
                        : mode != ChatUiMode.classic &&
                              c.messages.lastOrNull?.status == 'pending'
                        ? '对方正在输入中…'
                        : c.messages.lastOrNull?.text ?? '')
                    .characters
                    .take(90)
                    .join(),
            'hasDraft': c.draft.isNotEmpty,
            'time': c.messages.isEmpty
                ? ''
                : '${c.messages.last.created.hour.toString().padLeft(2, '0')}:${c.messages.last.created.minute.toString().padLeft(2, '0')}',
          },
      ],
      if (delta)
        'delta': {
          'index': values.length - 1,
          'message': _message(values.last, values.length - 1),
        }
      else
        'messages': [
          for (int i = 0; i < values.length; i++) _message(values[i], i),
        ],
    };
  }
}
