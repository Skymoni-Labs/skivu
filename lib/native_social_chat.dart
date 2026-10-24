import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'appearance.dart';
import 'assistant_reply_layout.dart';
import 'character_avatar.dart';
import 'chat_bubble_surface.dart';
import 'chat_controls.dart';
import 'chat_extras.dart';
import 'message_info_row.dart';
import 'native_social_media.dart';
import 'state.dart';
import 'sticker_library_page.dart';
import 'ui_plugins.dart';
import 'ui_host_binding.dart';
import 'virtual_wallet.dart';
import 'widgets.dart';

/// Native presenter for the existing conversation store. The parent owns the
/// wallpaper, Scaffold and keyboard resizing; this surface adds no IME inset.
class NativeSocialChat extends StatefulWidget {
  const NativeSocialChat({
    super.key,
    required this.mode,
    required this.go,
    required this.onBack,
    required this.onInfo,
    this.store,
    this.active = true,
    this.locateMessage,
  });

  final ChatUiMode mode;
  final ValueChanged<String> go;
  final VoidCallback onBack, onInfo;
  final DemoStore? store;
  final bool active;
  final Message? locateMessage;

  @override
  State<NativeSocialChat> createState() => _NativeSocialChatState();
}

class _NativeSocialChatState extends State<NativeSocialChat> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _keys = <Object, GlobalKey>{};
  late DemoStore _store;
  late Conversation _chat;
  List<_SocialChatItem> _items = [];
  bool _follow = true, _followQueued = false, _loadingDraft = false;
  int _seek = 0;
  double? _height;
  Color get _accent => widget.mode == ChatUiMode.qq
      ? const Color(0xff1497e8)
      : const Color(0xff07a95c);
  bool get _wechat => widget.mode == ChatUiMode.wechat;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? demo;
    _chat = _store.conversations[_store.conversation];
    _input.text = _chat.draft;
    _input.addListener(_draftChanged);
    _store.addListener(_update);
    virtualWallet.addListener(_update);
    _rebuildItems();
    _reader();
    if (widget.locateMessage == null) {
      _bottom();
    } else {
      _queueLocate(widget.locateMessage!);
    }
  }

  @override
  void didUpdateWidget(NativeSocialChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.store ?? demo;
    if (!identical(next, _store)) {
      _store.setChatReader(this, null);
      _store.removeListener(_update);
      _store = next;
      _store.addListener(_update);
      _switchChat(_store.conversations[_store.conversation]);
    }
    if (oldWidget.active != widget.active) {
      if (!widget.active) _focus.unfocus();
      _reader();
    }
    if (widget.locateMessage != null &&
        !identical(oldWidget.locateMessage, widget.locateMessage)) {
      _queueLocate(widget.locateMessage!);
    }
  }

  void _queueLocate(Message message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _chat.messages.contains(message)) _locate(message);
    });
  }

  void _draftChanged() {
    if (!_loadingDraft) _store.saveDraft(_chat, _input.text);
    if (mounted) setState(() {});
  }

  void _reader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _store.setChatReader(this, widget.active ? _chat.id : null);
    });
  }

  void _switchChat(Conversation next) {
    _seek++;
    _chat = next;
    _loadingDraft = true;
    _input.text = next.draft;
    _loadingDraft = false;
    _keys.clear();
    _follow = true;
    _reader();
    _bottom();
  }

  void _update() {
    if (!mounted) return;
    final next = _store.conversations[_store.conversation];
    if (!identical(next, _chat)) _switchChat(next);
    _rebuildItems();
    final ids = _items.map((item) => item.id).toSet();
    _keys.removeWhere((key, _) => !ids.contains(key));
    setState(() {});
    if (_follow) _bottom();
  }

  void _rebuildItems() {
    final cleared = _chat.interactionsClearedAt;
    _items = [
      for (final message in _chat.messages)
        if (message.user || message.status != 'pending')
          _SocialChatItem.message(message),
      for (final event in _chat.interactions)
        if (!_chat.hiddenInteractions.contains(event['id']))
          _SocialChatItem.event(event),
      for (final transaction
          in (virtualWallet.snapshot()['transactions'] as List)
              .whereType<Map>())
        if (transaction['chatId'] == _chat.id &&
            !_chat.hiddenInteractions.contains(transaction['id']) &&
            (cleared == null ||
                DateTime.parse(transaction['created']).isAfter(cleared)))
          _SocialChatItem.wallet(Map<String, dynamic>.from(transaction)),
    ]..sort((a, b) => a.created.compareTo(b.created));
  }

  @override
  void dispose() {
    _seek++;
    _store.setChatReader(this, null);
    _store.removeListener(_update);
    virtualWallet.removeListener(_update);
    _input.removeListener(_draftChanged);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _bottom() {
    if (_followQueued) return;
    _followQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followQueued = false;
      if (mounted && _follow) _seekBottom(++_seek);
    });
  }

  void _seekBottom(int token, {int attempt = 0, double? end, int stable = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _seek || !_follow || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      final reached = (_scroll.offset - target).abs() < .5;
      final settled = reached && end != null && (target - end).abs() < .5
          ? stable + 1
          : 0;
      if (!reached) _scroll.jumpTo(target);
      if (settled < 2 && attempt < 100) {
        _seekBottom(token, attempt: attempt + 1, end: target, stable: settled);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _locate(Object id) {
    _follow = false;
    setState(() {});
    _seekItem(id, ++_seek);
  }

  // Seek by laid-out indexes first, then align the actual lazy child.
  void _seekItem(Object id, int token, {int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _seek || !_scroll.hasClients) return;
      final index = _items.indexWhere((item) => item.id == id);
      if (index < 0) return;
      final target = _keys[id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .12,
            duration: const Duration(milliseconds: 220),
          ),
        );
        return;
      }
      final visible = <(int, double)>[];
      for (final entry in _keys.entries) {
        final box = entry.value.currentContext?.findRenderObject();
        if (box is RenderBox && box.attached && box.hasSize) {
          final i = _items.indexWhere((item) => item.id == entry.key);
          if (i >= 0) visible.add((i, box.size.height));
        }
      }
      visible.sort((a, b) => a.$1.compareTo(b.$1));
      final mean = visible.isEmpty
          ? 140.0
          : visible.fold<double>(0, (sum, item) => sum + item.$2) /
                visible.length;
      final anchor = visible.isEmpty ? 0 : visible[visible.length ~/ 2].$1;
      final position = _scroll.position;
      _scroll.jumpTo(
        (_scroll.offset + (index - anchor) * mean).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      if (attempt < 80) _seekItem(id, token, attempt: attempt + 1);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _latest() {
    setState(() => _follow = true);
    _bottom();
  }

  void _send() {
    if (_input.text.trim().isEmpty || _store.streaming) return;
    if (_input.text.length > 10000) {
      toast(context, '单条消息最多 10000 字符，完整草稿已保留，请分条发送。');
      return;
    }
    _follow = true;
    if (_store.send(_input.text, streamingOverride: false)) {
      _input.clear();
      _bottom();
    } else {
      toast(context, _store.lastError ?? '当前无法发送，请稍后重试。');
    }
  }

  Future<void> _confirm() async {
    _follow = true;
    if (!_store.confirmPending(streamingOverride: false)) {
      toast(context, _store.lastError ?? '没有待发送消息。');
    } else {
      _focus.unfocus();
      _bottom();
    }
  }

  Future<void> _discard() async {
    final chat = _chat;
    final yes = await _ask(
      '清空待发送消息？',
      '移除这${chat.queuedMessages.length}条尚未提交的消息。',
    );
    if (yes && mounted && identical(chat, _chat)) _store.discardQueued();
  }

  Future<bool> _ask(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _messageMenu(Message message) async {
    final chat = _chat;
    final media = _messageAttachment(message);
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in <(String, String, IconData)>[
              if (media != null) ...[
                ('open-media', '系统打开图片', Icons.open_in_new),
                ('save-media', '另存图片', Icons.save_alt),
              ],
              ('copy', '复制消息', Icons.copy),
              (
                'save',
                message.bookmarked ? '取消收藏' : '收藏消息',
                Icons.bookmark_outline,
              ),
              ('quote', '引用到输入框', Icons.format_quote),
              if (!message.user &&
                  identical(message, chat.messages.lastOrNull) &&
                  !_store.streaming)
                ('retry', '重新生成', Icons.refresh),
              (
                'delete',
                message.status == 'queued' ? '移除此条待发送消息' : '删除本轮对话',
                Icons.delete_outline,
              ),
            ])
              ListTile(
                leading: Icon(option.$3),
                title: Text(option.$2),
                onTap: () => Navigator.pop(sheet, option.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !identical(chat, _chat) || !chat.messages.contains(message))
      return;
    switch (choice) {
      case 'open-media':
        if (media != null) await openNativeChatAttachment(context, media);
      case 'save-media':
        if (media != null) await saveNativeChatAttachment(context, media);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) toast(context, '消息已复制');
      case 'save':
        message.bookmarked = !message.bookmarked;
        _store.changed();
        unawaited(_store.saveChats());
      case 'quote':
        _input.text = message.text;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
        _focus.requestFocus();
      case 'retry':
        _follow = true;
        _store.regenerate();
      case 'delete':
        final round = _store.roundMessages(chat.id, message);
        if (await _ask(
              '删除本轮对话？',
              '将移除本轮提问和回复，共 ${round.length} 条消息；正在生成的本轮回复也会停止。删除后无法恢复。',
            ) &&
            mounted) {
          _store.deleteRound(chat.id, message);
        }
    }
  }

  Map<String, dynamic>? _messageAttachment(Message message) {
    final data =
        message.imageData ??
        (message.kind == 'sticker'
            ? _store.stickerFor(message.stickerId)?.data
            : null);
    if (data == null) return null;
    return {
      'id': 'native-image-${message.created.microsecondsSinceEpoch}',
      'kind': 'image',
      'created': message.created.toIso8601String(),
      'user': message.user,
      'payload': {
        'name': '照片-${message.created.millisecondsSinceEpoch}.png',
        'data': data,
      },
    };
  }

  Future<void> _history() async {
    final chat = _chat;
    String query = '';
    bool saved = false;
    final id = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, change) {
          final items = _items
              .where(
                (item) =>
                    item.preview.contains(query) &&
                    (!saved || item.message?.bookmarked == true),
              )
              .toList();
          return SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .72,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('聊天记录', style: TextStyle(fontSize: 20)),
                      ),
                      FilterChip(
                        label: const Text('仅收藏'),
                        selected: saved,
                        onSelected: (value) => change(() => saved = value),
                      ),
                    ],
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索这段对话',
                    ),
                    onChanged: (value) => change(() => query = value),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, index) {
                        final item = items[index];
                        return ListTile(
                          title: Text(
                            item.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${item.user ? '我' : _speaker(item.message?.authorId).name} · ${_time(item.created)}',
                          ),
                          trailing: item.message?.bookmarked == true
                              ? const Icon(Icons.bookmark)
                              : const Icon(Icons.north_west),
                          onTap: () => Navigator.pop(sheet, item.id),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (id != null && mounted && identical(chat, _chat)) _locate(id);
  }

  Future<void> _tools() async {
    _focus.unfocus();
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in <(String, String, IconData)>[
              ('album', '相册', Icons.photo_library_outlined),
              ('camera', '拍摄照片', Icons.camera_alt_outlined),
              ('speech', '语音识别', Icons.mic_none),
              ('sticker', '表情包', Icons.emoji_emotions_outlined),
              ('call', '语音通话', Icons.call_outlined),
              ('redpacket', '红包 · 虚拟互动', Icons.redeem_outlined),
              ('transfer', '转账 · 虚拟互动', Icons.swap_horiz),
              ('gift', '礼物 · 本机虚拟互动', Icons.card_giftcard),
              ('file', '文件 · 本机附件', Icons.attach_file),
              ('location', '位置 · 手动填写', Icons.location_on_outlined),
              ('contact', '角色名片', Icons.person_outline),
              ('music', '音乐 · 本机音频', Icons.music_note),
              ('history', '查找聊天记录', Icons.search),
              ('models', '选择模型', Icons.tune),
            ])
              ListTile(
                leading: Icon(option.$3),
                title: Text(option.$2),
                onTap: () => Navigator.pop(sheet, option.$1),
              ),
            const ListTile(
              enabled: false,
              leading: Icon(Icons.videocam_outlined),
              title: Text('视频通话'),
              trailing: Text('开发中'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _follow = true;
    switch (action) {
      case 'album':
        await showChatMediaActions(context, streamingOverride: false);
      case 'camera':
        await sendSystemChatPhoto(
          context,
          source: ImageSource.camera,
          streamingOverride: false,
        );
      case 'speech':
        await composeChatMedia(
          context,
          photo: false,
          initiallyReal: true,
          streamingOverride: false,
        );
      case 'sticker':
        await showStickerPicker(context, streamingOverride: false);
      case 'call':
        widget.go('/call');
      case 'models':
        await showChatModelPicker(context);
      case 'history':
        await _history();
      case 'redpacket':
        await _composeWallet('redpacket');
      case 'transfer':
        await _composeWallet('transfer');
      case 'gift':
        await _composeWallet('gift');
      case 'file' || 'music':
        await _pickAttachment(action!);
      case 'location':
        await _location();
      case 'contact':
        await _contact();
    }
  }

  Persona _speaker(String? id) =>
      _store.personas
          .where((role) => role.id == (id ?? _chat.personaId))
          .firstOrNull ??
      _store.role;

  void _appendEvent(Conversation chat, Map<String, dynamic> event) {
    if (!mounted) return;
    if (!identical(chat, _chat)) {
      toast(context, '对话已切换，请重新选择附件。');
      return;
    }
    final failure = UiHostBinding(_store).mutate({
      'protocol': 1,
      'command': 'chatInteraction',
      'chatId': chat.id,
      'event': event,
    }, mode: widget.mode);
    if (failure != null)
      toast(context, failure);
    else {
      _follow = true;
      _bottom();
    }
  }

  Future<void> _pickAttachment(String kind) async {
    final chat = _chat;
    try {
      final event = await pickNativeChatFile(kind: kind);
      if (event != null) _appendEvent(chat, event);
    } catch (error) {
      if (mounted)
        toast(
          context,
          error is FormatException ? error.message : '附件未导入，请检查系统文件选择器后重试。',
        );
    }
  }

  Future<void> _location() async {
    final chat = _chat;
    final name = TextEditingController(), address = TextEditingController();
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('位置 · 手动填写'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('保存你填写的位置描述，不读取手机定位。'),
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: '地点名称'),
              ),
              TextField(
                controller: address,
                maxLength: 300,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '地址或位置描述'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(dialog, true);
            },
            child: const Text('保存到聊天'),
          ),
        ],
      ),
    );
    if (yes == true)
      _appendEvent(chat, {
        'id': 'native-${DateTime.now().microsecondsSinceEpoch}',
        'kind': 'location',
        'created': DateTime.now().toIso8601String(),
        'user': true,
        'payload': {'label': name.text.trim(), 'address': address.text.trim()},
      });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    address.dispose();
  }

  Future<void> _contact() async {
    final chat = _chat;
    final role = await showModalBottomSheet<Persona>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => ListView.builder(
        shrinkWrap: true,
        itemCount: _store.personas.length,
        itemBuilder: (_, index) {
          final role = _store.personas[index];
          return ListTile(
            leading: CharacterAvatar(persona: role),
            title: Text(role.name),
            subtitle: const Text('本机角色名片'),
            onTap: () => Navigator.pop(sheet, role),
          );
        },
      ),
    );
    if (role != null)
      _appendEvent(chat, {
        'id': 'native-${DateTime.now().microsecondsSinceEpoch}',
        'kind': 'contact',
        'created': DateTime.now().toIso8601String(),
        'user': true,
        'payload': {'roleId': role.id, 'name': role.name},
      });
  }

  Future<void> _composeWallet(String kind) async {
    final chat = _chat, role = _speaker(null);
    if (chat.groupMembers.isNotEmpty) {
      toast(context, '请在与角色的单独对话中使用虚拟红包和转账。');
      return;
    }
    final amount = TextEditingController(), note = TextEditingController();
    bool incoming = false, busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) => AlertDialog(
          title: Text(_walletTitle(kind)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('角色扮演互动，仅记录本机虚拟零钱。'),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '金额',
                    prefixText: '¥ ',
                  ),
                ),
                TextField(
                  controller: note,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('由${role.name}发给我'),
                  value: incoming,
                  onChanged: busy
                      ? null
                      : (value) => change(() => incoming = value),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(dialog).colorScheme.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!identical(chat, _chat)) {
                        change(() => error = '对话已切换，请重新操作。');
                        return;
                      }
                      final value = amount.text.trim();
                      if (!RegExp(r'^\d{1,6}(\.\d{1,2})?$').hasMatch(value)) {
                        change(() => error = '请填写有效金额，最多两位小数。');
                        return;
                      }
                      final cents = (double.parse(value) * 100).round();
                      change(() => busy = true);
                      final failure = await virtualWallet.interact(
                        requestId:
                            'native-${DateTime.now().microsecondsSinceEpoch}',
                        operation: 'create',
                        chatId: chat.id,
                        roleId: role.id,
                        roleName: role.name,
                        cents: cents,
                        note: note.text,
                        kind: kind,
                        incoming: incoming,
                      );
                      if (!dialog.mounted) return;
                      if (failure == null) {
                        chat.placeholder = false;
                        _store.changed();
                        unawaited(_store.saveChats());
                        Navigator.pop(dialog);
                      } else {
                        change(() {
                          busy = false;
                          error = failure;
                        });
                      }
                    },
              child: Text(busy ? '保存中…' : '确认'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    amount.dispose();
    note.dispose();
  }

  Future<void> _walletDetails(Map<String, dynamic> transaction) async {
    final chat = _chat;
    final operation = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _walletTitle(transaction['kind']),
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 16),
            Text(
              '¥${((transaction['cents'] as int) / 100).toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 32),
            ),
            Text(transaction['note'] as String? ?? ''),
            Text('仅本机角色扮演 · ${_walletState(transaction)}'),
            if (transaction['state'] == 'pending') ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(sheet, 'receive'),
                child: Text(transaction['incoming'] == true ? '领取' : '由角色收取'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheet, 'refund'),
                child: const Text('退回'),
              ),
            ],
          ],
        ),
      ),
    );
    if (operation == null || !mounted || !identical(chat, _chat)) return;
    final failure = await virtualWallet.interact(
      requestId: 'native-${DateTime.now().microsecondsSinceEpoch}',
      operation: operation,
      chatId: chat.id,
      roleId: transaction['roleId'],
      roleName: transaction['roleName'] ?? '',
      transactionId: transaction['id'],
    );
    if (failure != null && mounted) toast(context, failure);
  }

  String _walletState(Map<String, dynamic> value) => switch (value['state']) {
    'received' => '已领取',
    'refunded' => '已退回',
    _ => '待领取',
  };

  Future<void> _eventDetails(Map<String, dynamic> event) async {
    final payload = event['payload'] as Map;
    final kind = event['kind'];
    if (kind == 'contact') {
      final role = _store.personas
          .where((p) => p.id == payload['roleId'])
          .firstOrNull;
      if (role != null) {
        _store.persona = _store.personas.indexOf(role);
        widget.go('/characters/edit');
      } else {
        toast(context, '角色已不存在。');
      }
      return;
    }
    final audio = kind == 'audio' || kind == 'music';
    const audioChannel = MethodChannel('skivu/voice_call');
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          payload['name']?.toString() ?? payload['label']?.toString() ?? '聊天附件',
        ),
        content: kind == 'image'
            ? InteractiveViewer(
                child: Image.memory(
                  base64Decode((payload['data'] as String).split(',').last),
                  errorBuilder: (_, _, _) => const Text('图片无法显示'),
                ),
              )
            : SelectableText(
                kind == 'location'
                    ? '${payload['label']}\n${payload['address']}'
                    : kind == 'call'
                    ? '${payload['video'] == true ? '视频' : '语音'}通话 · ${payload['duration']} 秒'
                    : '${payload['name'] ?? ''}\n${payload['bytes'] ?? 0} 字节 · 本机附件',
              ),
        actions: [
          if (const {
            'image',
            'video',
            'audio',
            'music',
            'file',
          }.contains(kind)) ...[
            TextButton.icon(
              onPressed: () => openNativeChatAttachment(dialog, event),
              icon: const Icon(Icons.open_in_new),
              label: const Text('系统打开'),
            ),
            TextButton.icon(
              onPressed: () => saveNativeChatAttachment(dialog, event),
              icon: const Icon(Icons.save_alt),
              label: const Text('另存'),
            ),
          ],
          if (audio) ...[
            TextButton.icon(
              onPressed: () async {
                try {
                  await audioChannel.invokeMethod('playAudio', {
                    'bytes': base64Decode(
                      (payload['data'] as String).split(',').last,
                    ),
                  });
                } catch (_) {
                  if (dialog.mounted) toast(dialog, '此设备暂时无法播放该音频。');
                }
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await audioChannel.invokeMethod('stop');
                } catch (_) {}
              },
              child: const Text('停止'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    if (audio) {
      try {
        await audioChannel.invokeMethod('stop');
      } catch (_) {}
    }
  }

  Future<void> _hideItem(_SocialChatItem item) async {
    final chat = _chat;
    if (await _ask('移除此条本机记录？', '仅移除聊天里的显示，虚拟钱包账本保留。') &&
        mounted &&
        identical(chat, _chat)) {
      chat.hiddenInteractions.add(item.id as String);
      chat.interactions.removeWhere((event) => event['id'] == item.id);
      _store.changed();
      unawaited(_store.saveChats());
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Column(
      children: [
        _header(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_height != constraints.maxHeight) {
                _height = constraints.maxHeight;
                if (_follow) _bottom();
              }
              return Stack(
                children: [
                  if (_items.isEmpty)
                    Center(
                      child: Text(
                        '和${_speaker(null).name}聊点什么吧',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  NotificationListener<ScrollNotification>(
                    onNotification: (event) {
                      if (event is ScrollUpdateNotification &&
                              event.dragDetails != null ||
                          event is UserScrollNotification &&
                              event.direction != ScrollDirection.idle) {
                        // User inspection takes priority over a queued bottom
                        // seek, including the first few pixels of a drag.
                        if (_follow) {
                          _seek++;
                          setState(() => _follow = false);
                        }
                      }
                      return false;
                    },
                    child: ListView.builder(
                      key: ValueKey('social-chat-list-${_chat.id}'),
                      controller: _scroll,
                      // Keep frosted bubbles sampling the moving wallpaper, as
                      // in the original presenter rather than cached layers.
                      addRepaintBoundaries: false,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.fromLTRB(
                        appearance.flag('wideChat') ? 8 : 14,
                        18,
                        appearance.flag('wideChat') ? 8 : 14,
                        18,
                      ),
                      itemCount: _items.length,
                      itemBuilder: (context, index) => _item(_items[index]),
                    ),
                  ),
                  if (!_follow && _items.isNotEmpty)
                    Positioned(
                      right: 14,
                      bottom: 12,
                      child: FilledButton.tonalIcon(
                        onPressed: _latest,
                        icon: const Icon(
                          Icons.keyboard_double_arrow_down,
                          size: 18,
                        ),
                        label: const Text('回到最新'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        GestureDetector(onHorizontalDragStart: (_) {}, child: _composer()),
      ],
    ),
  );

  Widget _header() => Container(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    decoration: BoxDecoration(
      color: (_wechat ? const Color(0xfff3f3f3) : Colors.white).withValues(
        alpha: .92,
      ),
      border: const Border(
        bottom: BorderSide(color: Color(0x16000000), width: .5),
      ),
    ),
    child: SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            onPressed: () {
              _focus.unfocus();
              widget.onBack();
            },
            icon: const Icon(Icons.chevron_left, size: 30),
          ),
          Expanded(
            child: InkWell(
              onTap: widget.onInfo,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: _wechat
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    _chat.groupMembers.isEmpty
                        ? _speaker(null).name
                        : _chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_store.streaming)
                    Text(
                      '正在回复…',
                      style: TextStyle(fontSize: 10, color: _accent),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '查找聊天记录',
            onPressed: _history,
            icon: const Icon(Icons.search, size: 22),
          ),
          IconButton(
            tooltip: '聊天信息',
            onPressed: widget.onInfo,
            icon: Icon(_wechat ? Icons.more_horiz : Icons.menu, size: 25),
          ),
        ],
      ),
    ),
  );

  Widget _composer() {
    final count = _chat.queuedMessages.length;
    return Container(
      key: const ValueKey('social-chat-composer'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xfff7f7f7).withValues(alpha: .95),
        border: const Border(
          top: BorderSide(color: Color(0x18000000), width: .5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_chat.confirmBeforeReply || count > 0)
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      count > 0 ? '$count 条待发送' : '分条输入，确认后统一回复',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                if (count > 0)
                  IconButton(
                    tooltip: '清空待发送消息',
                    onPressed: _store.streaming ? null : _discard,
                    icon: const Icon(Icons.delete_outline, size: 19),
                  ),
                TextButton(
                  onPressed: count == 0 || _store.streaming ? null : _confirm,
                  child: const Text('确认发送'),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '语音识别',
                onPressed: _store.streaming
                    ? null
                    : () => composeChatMedia(
                        context,
                        photo: false,
                        initiallyReal: true,
                        streamingOverride: false,
                      ),
                icon: const Icon(Icons.mic_none, size: 26),
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('social-chat-input'),
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  // Restored legacy drafts remain intact. Apply the normal
                  // input limit only after the user reduces one below it.
                  inputFormatters: [
                    if (_input.text.length <= 10000)
                      LengthLimitingTextInputFormatter(10000),
                  ],
                  decoration: InputDecoration(
                    hintText: '发消息…',
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 11,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(_wechat ? 5 : 20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '表情包',
                onPressed: _store.streaming
                    ? null
                    : () =>
                          showStickerPicker(context, streamingOverride: false),
                icon: const Icon(Icons.emoji_emotions_outlined, size: 26),
              ),
              if (_store.streaming)
                IconButton(
                  tooltip: '停止生成',
                  onPressed: _store.stop,
                  color: _accent,
                  icon: const Icon(Icons.stop_circle_outlined, size: 28),
                )
              else if (_input.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      minimumSize: const Size(50, 38),
                    ),
                    onPressed: _send,
                    child: const Text('发送'),
                  ),
                )
              else
                IconButton(
                  tooltip: '更多功能',
                  onPressed: _tools,
                  icon: const Icon(Icons.add_circle_outline, size: 28),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _item(_SocialChatItem item) {
    final key = _keys.putIfAbsent(item.id, () => GlobalKey());
    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: _store.compact ? 14 : 22),
      child: item.message != null ? _message(item.message!) : _attachment(item),
    );
  }

  Widget _avatar(bool user, Persona role) => GestureDetector(
    onTap: () {
      if (user) {
        editUserCard(context);
      } else {
        _store.persona = _store.personas.indexOf(role);
        widget.go('/characters/edit');
      }
    },
    child: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: user
            ? const Color(0xffcce6fa)
            : role.color.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(
          _wechat || appearance.flag('squareAvatars') ? 7 : 19,
        ),
      ),
      child: user
          ? UserAvatar(
              size: 38,
              square: _wechat || appearance.flag('squareAvatars'),
            )
          : CharacterAvatar(
              persona: role,
              size: 38,
              square: _wechat || appearance.flag('squareAvatars'),
            ),
    ),
  );

  Widget _message(Message message) {
    final role = _speaker(message.authorId);
    final layout = appearance.text('assistantBubbleLayout');
    final content = GestureDetector(
      onTap: _messageAttachment(message) == null
          ? null
          : () => _eventDetails(_messageAttachment(message)!),
      onHorizontalDragStart: _messageAttachment(message) == null
          ? null
          : (_) {},
      onLongPress: () => _messageMenu(message),
      child: Column(
        crossAxisAlignment: !message.user && layout != 'centered'
            ? CrossAxisAlignment.stretch
            : message.user
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (!message.user &&
              (_chat.groupMembers.isNotEmpty || appearance.flag('showRole')))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                role.name,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
          ChatBubbleSurface(
            key: ValueKey(
              'social-message-${message.created.microsecondsSinceEpoch}',
            ),
            user: message.user,
            contentPadding: AssistantReplyLayout.bubblePadding(
              message.user ? 'centered' : layout,
            ),
            child: message.kind == 'text'
                ? Text(
                    message.text.isNotEmpty
                        ? message.text
                        : message.status == 'pending'
                        ? '正在思考…'
                        : message.status == 'cancelled'
                        ? '已停止生成'
                        : '未收到回复',
                    style: chatMessageStyle(context, message.user),
                  )
                : TypedMessageBody(message: message),
          ),
          if (message.contextNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message.contextNotice!,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
          if (message.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    message.error!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  if (!_store.streaming &&
                      identical(message, _chat.messages.lastOrNull))
                    TextButton(
                      onPressed: _store.regenerate,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
          if (message.status == 'queued')
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('待确认', style: TextStyle(fontSize: 11)),
                IconButton(
                  tooltip: '移除此条待发送消息',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () => _store.deleteRound(_chat.id, message),
                ),
              ],
            ),
          if (!message.user)
            MessageInfoRow(message: message)
          else if (appearance.flag('showTime'))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _time(message.created),
                style: TextStyle(fontSize: 10, color: muted),
              ),
            ),
          if (message.bookmarked)
            Icon(Icons.bookmark, size: 13, color: _accent),
        ],
      ),
    );
    if (!message.user) {
      return AssistantReplyLayout(
        layout: layout,
        wide: appearance.flag('wideChat'),
        avatar: appearance.flag('avatars') ? _avatar(false, role) : null,
        thinking: appearance.flag('showThinking') ? message.thinking : null,
        child: content,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: content),
        if (appearance.flag('avatars')) ...[
          const SizedBox(width: 9),
          _avatar(true, role),
        ],
      ],
    );
  }

  Widget _attachment(_SocialChatItem item) {
    final data = item.data!;
    final role = _speaker(item.wallet ? data['roleId'] : null);
    final payload = item.wallet ? data : data['payload'] as Map;
    Widget body;
    if (!item.wallet && data['kind'] == 'image') {
      body = Image.memory(
        base64Decode((payload['data'] as String).split(',').last),
        width: 210,
        height: 160,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Text('图片无法显示'),
      );
    } else {
      final icon = item.wallet
          ? data['kind'] == 'redpacket'
                ? Icons.redeem
                : Icons.swap_horiz
          : switch (data['kind']) {
              'video' => Icons.videocam_outlined,
              'audio' || 'music' => Icons.audiotrack_outlined,
              'location' => Icons.location_on_outlined,
              'contact' => Icons.person_outline,
              'call' => Icons.call_outlined,
              _ => Icons.insert_drive_file_outlined,
            };
      body = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 160, maxWidth: 235),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: item.wallet ? const Color(0xffdb7b26) : _accent,
                ),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    item.preview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (item.wallet) ...[
              const SizedBox(height: 8),
              Text('¥${((data['cents'] as int) / 100).toStringAsFixed(2)}'),
              Text(
                '虚拟互动 · ${_walletState(data)}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
            if (!item.wallet && data['kind'] == 'location')
              Text(
                payload['address'] as String? ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
          ],
        ),
      );
    }
    final bubble = GestureDetector(
      onHorizontalDragStart: (_) {},
      onTap: () => item.wallet ? _walletDetails(data) : _eventDetails(data),
      onLongPress: () => _hideItem(item),
      child: ChatBubbleSurface(user: item.user, child: body),
    );
    return Row(
      mainAxisAlignment: item.user
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!item.user && appearance.flag('avatars')) ...[
          _avatar(false, role),
          const SizedBox(width: 9),
        ],
        Flexible(child: bubble),
        if (item.user && appearance.flag('avatars')) ...[
          const SizedBox(width: 9),
          _avatar(true, role),
        ],
      ],
    );
  }

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class _SocialChatItem {
  _SocialChatItem.message(Message value)
    : message = value,
      data = null,
      wallet = false;
  _SocialChatItem.event(Map<String, dynamic> value)
    : data = value,
      message = null,
      wallet = false;
  _SocialChatItem.wallet(Map<String, dynamic> value)
    : data = value,
      message = null,
      wallet = true;
  final Message? message;
  final Map<String, dynamic>? data;
  final bool wallet;
  Object get id => message ?? data!['id'];
  DateTime get created => message?.created ?? DateTime.parse(data!['created']);
  bool get user =>
      message?.user ??
      (wallet ? data!['incoming'] != true : data!['user'] != false);
  String get preview =>
      message?.text ??
      (wallet
          ? _walletTitle(data!['kind'])
          : switch (data!['kind']) {
              'image' => '[图片] ${data!['payload']['name']}',
              'location' => '[位置] ${data!['payload']['label']}',
              'contact' => '[角色名片] ${data!['payload']['name']}',
              'call' => '[通话] ${data!['payload']['duration']} 秒',
              _ => '[附件] ${data!['payload']['name'] ?? ''}',
            });
}

String _walletTitle(String kind) => switch (kind) {
  'redpacket' => '虚拟红包',
  'gift' => '虚拟礼物',
  _ => '虚拟转账',
};
