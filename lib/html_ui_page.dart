import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'state.dart';
import 'chat_controls.dart';
import 'ui_plugins.dart';
import 'ui_host_binding.dart';
import 'social_activity.dart';
import 'social_settings.dart';
import 'virtual_wallet.dart';
import 'appearance.dart';
import 'appearance_settings.dart';
import 'wallpaper.dart';
import 'glass_preferences.dart';
import 'chat_backdrop.dart';
import 'ui_chat_appearance.dart';
import 'chat_extras.dart';
import 'package:image_picker/image_picker.dart';
import 'ui_document_port.dart';
import 'ui_document_native.dart'
    if (dart.library.js_interop) 'ui_document_web.dart'
    as document;

class HtmlUiPage extends StatefulWidget {
  const HtmlUiPage({
    super.key,
    required this.go,
    required this.openNavigation,
    required this.openWorkspace,
  });
  final ValueChanged<String> go;
  final VoidCallback openNavigation, openWorkspace;
  @override
  State<HtmlUiPage> createState() => _HtmlUiPageState();
}

class _HtmlUiPageState extends State<HtmlUiPage> {
  late final binding = UiHostBinding(demo);
  UiPush? _push;
  Timer? _timer;
  bool _force = true, _sending = false, _dirty = false;
  int _homeRevision = uiPlugins.homeRevision;
  int _socialRevision = -1;
  String? _view, _ack, _error;
  String? _replyChat, _notice;
  final _chatAppearance = UiChatAppearance();
  ChatBackdropController? _backdrop;
  bool _appearanceDirty = true;
  Map<String, String?>? _lastAppearanceAssets;
  double _safeTop = 0;
  @override
  void initState() {
    super.initState();
    _view = uiPlugins.conversationVisible ? 'chat' : 'inbox';
    demo.addListener(_queue);
    socialActivity.addListener(_queue);
    virtualWallet.addListener(_queue);
    uiPlugins.addListener(_preferences);
    appearance.addListener(_appearanceChanged);
    wallpaper.addListener(_appearanceChanged);
    glassPreferences.addListener(_appearanceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final safeTop = MediaQuery.paddingOf(context).top;
    if (_safeTop != safeTop) {
      _safeTop = safeTop;
      _queue();
    }
    final next = ChatBackdropScope.maybeOf(context);
    if (identical(next, _backdrop)) return;
    _backdrop?.removeListener(_appearanceChanged);
    _backdrop = next;
    _backdrop?.addListener(_appearanceChanged);
    _appearanceChanged();
  }

  void _appearanceChanged() {
    _appearanceDirty = true;
    _queue();
  }

  @override
  void dispose() {
    demo.removeListener(_queue);
    socialActivity.removeListener(_queue);
    virtualWallet.removeListener(_queue);
    uiPlugins.removeListener(_preferences);
    appearance.removeListener(_appearanceChanged);
    wallpaper.removeListener(_appearanceChanged);
    glassPreferences.removeListener(_appearanceChanged);
    _backdrop?.removeListener(_appearanceChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _preferences() {
    if (_homeRevision != uiPlugins.homeRevision) {
      _homeRevision = uiPlugins.homeRevision;
      _view = 'inbox';
    }
    _force = true;
    _queue();
  }

  void _queue() {
    if (demo.streaming) {
      _replyChat = binding.selected.id;
    } else if (_replyChat != null) {
      final chat = binding.selected;
      if (_replyChat == chat.id &&
          chat.replyReminder &&
          !chat.muted &&
          chat.messages.lastOrNull?.status == 'complete' &&
          chat.messages.lastOrNull?.user == false) {
        _notice = '${demo.role.name}回复了你';
      }
      _replyChat = null;
    }
    _dirty = true;
    _timer ??= Timer(const Duration(milliseconds: 40), () {
      _timer = null;
      _flush();
    });
  }

  Future<void> _flush() async {
    if (!mounted || _push == null || _sending) return;
    _sending = true;
    _dirty = false;
    final value = binding.snapshot(uiPlugins.mode, force: _force, view: _view);
    value['safeTop'] = _safeTop;
    if (_force || _appearanceDirty) {
      _appearanceDirty = false;
      value['appearance'] = _chatAppearance.values(
        glassEnabled: demo.prefs['毛玻璃效果'] ?? true,
      );
      try {
        final assets = await _chatAppearance.assets(_backdrop);
        if (!mounted) return;
        if (_lastAppearanceAssets == null ||
            !mapEquals(assets, _lastAppearanceAssets)) {
          value['appearanceAssets'] = assets;
          _lastAppearanceAssets = assets;
        }
      } catch (_) {
        _appearanceDirty = true;
      }
      final scene = _backdrop?.backgroundKey.currentContext?.findRenderObject();
      final pane = context.findRenderObject();
      if (scene is RenderBox && pane is RenderBox) {
        final offset = scene.globalToLocal(pane.localToGlobal(Offset.zero));
        value['appearanceScene'] = {
          'width': scene.size.width,
          'height': scene.size.height,
          'x': offset.dx,
          'y': offset.dy,
        };
      }
    }
    if (_force) {
      value['wallet'] = virtualWallet.snapshot();
      value['groupDefaults'] = socialSettings.value.toJson();
    }
    if (_force || _socialRevision != socialActivity.revision) {
      value['posts'] = socialActivity.feed(
        uiPlugins.mode == ChatUiMode.qq ? 'qq' : 'wx',
      );
      _socialRevision = socialActivity.revision;
    }
    value['socialError'] = socialActivity.error;
    if (_force)
      value['favorites'] = [
        for (final c in demo.conversations)
          for (final m in c.messages)
            if (m.bookmarked) m.text,
      ].take(100).toList();
    if (_ack != null) value['ack'] = _ack;
    if (_error != null) value['error'] = _error;
    if (_notice != null) value['notice'] = _notice;
    _force = false;
    _view = null;
    _ack = null;
    _error = null;
    _notice = null;
    try {
      await _push!(value);
    } catch (_) {
      _force = true;
    } finally {
      _sending = false;
      if (_dirty && mounted) _queue();
    }
  }

  Future<void> command(Map<String, dynamic> value) async {
    if (!mounted) return;
    if (!binding.valid(value)) return;
    final action = value['command'];
    if (action == 'ready') _lastAppearanceAssets = null;
    if (action == 'classicUi') {
      final saved = await uiPlugins.apply(ChatUiMode.classic);
      if (!saved && mounted) {
        _error = uiPlugins.error;
        _force = true;
        _queue();
      }
      return;
    }
    final error = binding.mutate(value, mode: uiPlugins.mode);
    if (error != null) {
      _error = error;
      _force = true;
      _queue();
      return;
    }
    if (action == 'selectChat' ||
        action == 'newChat' ||
        action == 'createGroup' ||
        action == 'groupConfig') {
      _view = 'chat';
      uiPlugins.showConversation();
    }
    if (action == 'send') _ack = 'send';
    if (action == 'confirmBatch') _ack = 'confirmBatch';
    if (action == 'chatInteraction') {
      await demo.saveChats();
      if (demo.storageError == null)
        _ack = 'chatInteraction';
      else
        _error = demo.storageError;
    }
    if (action == 'chatAppearance') {
      final section = value['section'];
      if (section == 'background' || section == 'bubbles')
        await _openAppearance(section == 'background' ? 1 : 2);
    } else if (action == 'clearChat') {
      await _clearChat(binding.selected);
    } else if (action == 'editRole') {
      final id = value['roleId'];
      if (id is String && binding.roleFor(id) != null) {
        demo.persona = demo.personas.indexWhere((p) => p.id == id);
        widget.go('/characters/edit');
      }
    } else if (action == 'models') {
      await showChatModelPicker(context);
    } else if (action == 'composeMedia') {
      if (value['kind'] == 'photo' && value['source'] == 'camera') {
        await sendSystemChatPhoto(
          context,
          source: ImageSource.camera,
          streamingOverride: false,
        );
      } else if (value['kind'] == 'photo' && value['real'] == true) {
        await showChatMediaActions(context, streamingOverride: false);
      } else if (value['kind'] == 'photo' || value['kind'] == 'voice') {
        await composeChatMedia(
          context,
          photo: value['kind'] == 'photo',
          initiallyReal: value['real'] == true,
          streamingOverride: false,
        );
      }
    } else if (action == 'stickerLibrary') {
      widget.go('/stickers');
    } else if (action == 'discardBatch') {
      final chat = binding.selected;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('清空待发送消息？'),
          content: Text('移除这${chat.queuedMessages.length}条尚未提交的消息。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('清空'),
            ),
          ],
        ),
      );
      if (yes == true && mounted && identical(chat, binding.selected))
        demo.discardQueued();
    } else if (action == 'userCard') {
      await editUserCard(context);
    } else if (action == 'userAvatar') {
      await editUserAvatar(context);
    } else if (action == 'roles') {
      widget.go('/characters');
    } else if (action == 'walletInteraction') {
      final chat = binding.selected;
      final role = chat.personaId == null
          ? null
          : binding.roleFor(chat.personaId!);
      final operation = value['operation'], requestId = value['requestId'];
      final cents = value['cents'] ?? 0, note = value['note'] ?? '';
      final kind = value['kind'] ?? 'transfer', transactionId = value['id'];
      if (role == null ||
          operation is! String ||
          requestId is! String ||
          cents is! int ||
          note is! String ||
          kind is! String ||
          (transactionId != null && transactionId is! String)) {
        _error = '虚拟交易信息不正确。';
      } else {
        _error = await virtualWallet.interact(
          requestId: requestId,
          operation: operation,
          chatId: chat.id,
          roleId: role.id,
          roleName: role.name,
          cents: cents,
          note: note,
          kind: kind,
          transactionId: transactionId as String?,
          incoming: value['incoming'] == true,
          cover: value['cover'] is String ? value['cover'] : 'classic',
        );
        if (_error == null) {
          _ack = 'walletInteraction';
          chat.placeholder = false;
          demo.changed();
          demo.saveChats();
          if (operation == 'create' && binding.selected.id == chat.id)
            _view = 'chat';
        }
      }
    } else if (action == 'walletChange') {
      final operation = value['operation'],
          cents = value['cents'],
          requestId = value['requestId'];
      final role = binding.roleFor(
        value['roleId'] is String ? value['roleId'] as String : '',
      );
      final note = value['note'] ?? '';
      _error =
          operation is String &&
              cents is int &&
              requestId is String &&
              note is String &&
              (operation == 'set' || role != null)
          ? await virtualWallet.change(
              requestId: requestId,
              operation: operation,
              cents: cents,
              roleId: role?.id ?? '',
              roleName: role?.name ?? '',
              note: note,
            )
          : '虚拟钱包信息不正确';
      if (_error == null) _ack = 'walletChange';
    } else if (action == 'groupPreferences') {
      final members = value['members'];
      if (members is! List ||
          members.isEmpty ||
          members.length > 100 ||
          members.any((id) => id is! String || binding.roleFor(id) == null)) {
        _error = '请至少选择一位现有角色。';
      } else {
        final saved = await socialSettings.save(
          SocialConfig.fromJson({
            ...socialSettings.value.toJson(),
            'groupMembers': members.toSet().toList(),
          }),
        );
        if (saved)
          widget.go('/settings/social');
        else
          _error = socialSettings.error;
      }
    } else if (action == 'socialSettings') {
      widget.go('/settings/social');
    } else if (action == 'importPosts') {
      final rows = value['posts'];
      _error = rows is List
          ? await socialActivity.importPosts(
              uiPlugins.mode == ChatUiMode.qq ? 'qq' : 'wx',
              rows,
            )
          : '旧动态格式不正确';
      if (_error == null) _ack = 'importPosts';
    } else if (action == 'publishPost') {
      final text = value['text'], images = value['images'];
      _error =
          text is String && images is List && images.every((v) => v is String)
          ? socialActivity.publish(
              uiPlugins.mode == ChatUiMode.qq ? 'qq' : 'wx',
              text,
              images.cast<String>(),
            )
          : '动态格式不正确';
      if (_error == null) _ack = 'publishPost';
    } else if (action == 'postAction') {
      final id = value['id'],
          operation = value['operation'],
          text = value['text'] ?? '';
      _error = id is String && operation is String && text is String
          ? socialActivity.interact(operation, id, text: text)
          : '动态操作格式不正确';
      if (_error == null) _ack = 'postAction';
    } else if (action == 'settings') {
      widget.go('/settings');
    } else if (action == 'call') {
      widget.go('/call');
    } else if (action == 'drawer') {
      if (value['side'] == 'left') widget.openNavigation();
      if (value['side'] == 'right') widget.openWorkspace();
    } else if (action == 'messageMenu') {
      final message = binding.messageFor(value);
      if (message != null) await _messageMenu(message, binding.selected.id);
    } else if (action == 'chatMenu') {
      final chat = demo.conversations
          .where((c) => c.id == value['id'])
          .firstOrNull;
      if (chat != null) await _chatMenu(chat);
    }
    if (!mounted) return;
    _force = action != 'draft';
    _queue();
  }

  Future<void> _openAppearance(int section) async {
    final legacy = binding.selected.chatBackground;
    if (section == 1 &&
        legacy != null &&
        wallpaper.data == null &&
        appearance.text('videoAsset').isEmpty) {
      try {
        await wallpaper.importImage(base64Decode(legacy.split(',').last));
        appearance.set('backgroundEnabled', true);
        await appearance.save();
      } catch (_) {
        // Preserve the archive even if an old image cannot be imported.
      }
      if (!mounted) return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .92,
        child: Column(
          children: [
            ListTile(
              title: Text(section == 1 ? '自定义背景' : '聊天气泡'),
              subtitle: const Text('与 Skivu 原版共用外观配置，修改后同步生效'),
              trailing: IconButton(
                tooltip: '完成',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(sheet),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                child: AppearanceSettings(initialSection: section),
              ),
            ),
          ],
        ),
      ),
    );
    _appearanceChanged();
  }

  Future<void> _clearChat(Conversation chat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空聊天记录？'),
        content: const Text('只清空当前这段对话，保留角色与对话入口。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || binding.selected.id != chat.id) return;
    final backup = demo.clearChatMessages(chat.id);
    if (backup != null && mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已清空当前聊天记录'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => demo.restoreClearedMessages(backup),
          ),
        ),
      );
  }

  Future<void> _chatMenu(Conversation chat) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(title: Text(chat.title)),
        ListTile(
          title: Text(chat.pinned ? '取消置顶' : '置顶'),
          onTap: () {
            Navigator.pop(sheet);
            demo.toggleChatPin(chat.id);
          },
        ),
        ListTile(
          title: const Text('重命名'),
          onTap: () async {
            Navigator.pop(sheet);
            final input = TextEditingController(text: chat.title);
            final title = await showDialog<String>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('重命名对话'),
                content: TextField(controller: input, maxLength: 80),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c, input.text),
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
            if (title != null && mounted) demo.renameChat(chat.id, title);
            await Future<void>.delayed(const Duration(milliseconds: 250));
            input.dispose();
          },
        ),
        ListTile(
          title: const Text('删除对话'),
          onTap: () async {
            Navigator.pop(sheet);
            final yes = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('删除对话？'),
                content: Text('将删除“${chat.title}”及其记录，角色卡和其他对话保留。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            );
            if (yes == true && mounted) demo.deleteChat(chat.id);
          },
        ),
      ],
    ),
  );

  Future<void> _messageMenu(Message message, String id) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('复制消息'),
              onTap: () async {
                Navigator.pop(sheet);
                await Clipboard.setData(ClipboardData(text: message.text));
              },
            ),
            ListTile(
              title: Text(message.bookmarked ? '取消收藏' : '收藏消息'),
              onTap: () {
                Navigator.pop(sheet);
                message.bookmarked = !message.bookmarked;
                demo.changed();
                demo.saveChats();
              },
            ),
            if (message.thinking?.isNotEmpty == true)
              ListTile(
                title: const Text('查看思考过程'),
                onTap: () {
                  Navigator.pop(sheet);
                  showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('思考过程'),
                      content: SingleChildScrollView(
                        child: SelectableText(message.thinking!),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ListTile(
              title: const Text('删除本轮对话'),
              onTap: () async {
                Navigator.pop(sheet);
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('删除本轮对话？'),
                    content: const Text('仅删除这一轮提问与回复，其他对话保留。删除后无法恢复。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('删除本轮'),
                      ),
                    ],
                  ),
                );
                if (yes == true && mounted) demo.deleteRound(id, message);
              },
            ),
          ],
        ),
      );
  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
    child: document.buildUiDocument(
      onCommand: command,
      onReady: (push) {
        _push = push;
        _force = true;
        _queue();
      },
    ),
  );
}
