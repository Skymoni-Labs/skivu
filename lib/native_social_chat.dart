import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'appearance.dart';
import 'native_social_portrait.dart';
import 'chat_bubble_surface.dart';
import 'chat_controls.dart';
import 'chat_extras.dart';
import 'message_info_row.dart';
import 'native_social_media.dart';
import 'native_social_icons.dart';
import 'native_social_chat_widgets.dart';
import 'native_social_media_preview.dart';
import 'native_social_finance.dart';
import 'ui_chat_appearance.dart';
import 'glass_preferences.dart';
import 'native_social_local_options.dart';
import 'state.dart';
import 'open_plugin_companion_ui.dart';
import 'ui_plugins.dart';
import 'ui_host_binding.dart';
import 'virtual_wallet.dart';
import 'widgets.dart';
import 'open_plugin_page.dart';

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
    this.navigate,
    this.onRole,
  });

  final ChatUiMode mode;
  final ValueChanged<String> go;
  final VoidCallback onBack, onInfo;
  final DemoStore? store;
  final bool active;
  final Message? locateMessage;
  final ValueChanged<String>? navigate;
  final ValueChanged<String>? onRole;

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
  int _mediaPause = 0;
  double? _height;
  double _availableHeight = 900;
  String _panel = '';
  bool _voiceMode = false;
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
    nativeSocialLocalOptions.addListener(_update);
    glassPreferences.addListener(_update);
    _focus.addListener(_focusChanged);
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

  void _focusChanged() {
    if (_focus.hasFocus && _panel.isNotEmpty) setState(() => _panel = '');
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
    _panel = '';
    _voiceMode = false;
    _follow = true;
    _reader();
    _bottom();
  }

  int _companionDraftRevision = 0;
  void _update() {
    if (!mounted) return;
    final next = _store.conversations[_store.conversation];
    if (_companionDraftRevision != next.draftRevision) {
      _companionDraftRevision = next.draftRevision;
      _loadingDraft = true;
      _input.text = next.draft;
      _loadingDraft = false;
    }
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
    nativeSocialLocalOptions.removeListener(_update);
    glassPreferences.removeListener(_update);
    _focus.removeListener(_focusChanged);
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
      _panel = '';
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
    final choice = await _fullPage<String>(
      '消息',
      (sheet) => SingleChildScrollView(
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
    if (data == null || data.startsWith('data:image/gif;')) return null;
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
    var query = '';
    var saved = false;
    final id = await _fullPage<Object>(
      '查找聊天记录',
      (page) => StatefulBuilder(
        builder: (page, change) {
          final items = _items
              .where(
                (item) =>
                    item.preview.toLowerCase().contains(query.toLowerCase()) &&
                    (!saved || item.message?.bookmarked == true),
              )
              .toList();
          return Column(
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: NativeSocialIcon('search', size: 20),
                          hintText: '搜索这段对话',
                          filled: true,
                          fillColor: Color(0xfff5f5f5),
                          isDense: true,
                          border: InputBorder.none,
                        ),
                        onChanged: (value) => change(() => query = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilterChip(
                      label: const Text('仅收藏'),
                      selected: saved,
                      onSelected: (value) => change(() => saved = value),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, index) {
                    final item = items[index];
                    return Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(
                            color: Color(0xffeeeeee),
                            width: .5,
                          ),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        title: Text(
                          item.preview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${item.user ? '我' : _speaker(item.message?.authorId).name} · ${_time(item.created)}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff999999),
                            ),
                          ),
                        ),
                        onTap: () => Navigator.pop(page, item.id),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
    if (id != null && mounted && identical(chat, _chat)) _locate(id);
  }

  void _tools() => _togglePanel('more');

  void _togglePanel(String kind) {
    _focus.unfocus();
    setState(() {
      _voiceMode = false;
      _panel = _panel == kind ? '' : kind;
    });
    if (_follow) _bottom();
  }

  Future<T?> _fullPage<T>(
    String title,
    Widget Function(BuildContext) content, {
    bool interaction = false,
    bool more = true,
  }) => Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (page) => Scaffold(
        backgroundColor: interaction && !_wechat
            ? const Color(0xfff3f4f6)
            : const Color(0xffededed),
        appBar: AppBar(
          toolbarHeight: 54,
          centerTitle: true,
          elevation: 0,
          backgroundColor: interaction && !_wechat
              ? Colors.white
              : const Color(0xffededed),
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.pop(page),
            icon: const NativeSocialIcon('chevron-left'),
          ),
          title: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
          ),
          actions: interaction && more
              ? [
                  IconButton(
                    tooltip: '更多',
                    onPressed: () => _interactionMore(page),
                    icon: const NativeSocialIcon('more'),
                  ),
                ]
              : null,
        ),
        body: SafeArea(top: false, child: content(page)),
      ),
    ),
  );

  Future<void> _interactionMore(BuildContext origin) async {
    final selected = await _fullPage<String>(
      '更多',
      (page) => SingleChildScrollView(
        padding: _wechat ? EdgeInsets.zero : const EdgeInsets.all(14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_wechat ? 0 : 12),
          child: Column(
            children: [
              for (final item in [
                ('wallet', '钱包', 'wallet'),
                ('models', '选择模型', 'sparkles'),
                ('settings', '设置', 'settings'),
              ])
                ListTile(
                  minTileHeight: 58,
                  minVerticalPadding: 0,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  tileColor: Colors.white,
                  leading: NativeSocialIcon(item.$3, size: 22),
                  title: Text(item.$2, style: const TextStyle(fontSize: 16)),
                  onTap: () => Navigator.pop(page, item.$1),
                ),
            ],
          ),
        ),
      ),
      interaction: true,
      more: false,
    );
    if (!mounted || !origin.mounted || selected == null) return;
    if (selected == 'models') {
      await showChatModelPicker(origin);
    } else {
      Navigator.pop(origin);
      if (selected == 'settings') {
        widget.go('/settings');
      } else if (widget.navigate != null) {
        widget.navigate!('wallet');
      } else {
        toast(context, '请从社交页面的钱包入口查看本机账本。');
      }
    }
  }

  Future<void> _voiceCallPreview() async {
    final chat = _chat, role = _speaker(_chat.personaId);
    await _fullPage<void>(
      '语音通话',
      (page) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 70, 24, 30),
        children: [
          Center(
            child: NativeSocialPortrait(
              mode: widget.mode,
              persona: role,
              size: 86,
              large: true,
              borderRadius: 12,
              store: _store,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            role.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w400),
          ),
          const SizedBox(height: 15),
          const Text(
            '使用 Skivu 角色语音引擎',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xff888888)),
          ),
          const SizedBox(height: 45),
          Center(
            child: SizedBox(
              height: 48,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                icon: const NativeSocialIcon(
                  'phone',
                  color: Colors.white,
                  size: 22,
                ),
                label: const Text('开始语音通话'),
                onPressed: () {
                  if (!identical(chat, _chat) ||
                      !_store.personas.contains(role)) {
                    toast(page, '对话已切换，请重新打开语音通话。');
                    return;
                  }
                  Navigator.pop(page);
                  widget.go('/call');
                },
              ),
            ),
          ),
        ],
      ),
      interaction: true,
    );
  }

  void _insertEmoji(String value) {
    final selection = _input.selection;
    final start = selection.isValid ? selection.start : _input.text.length;
    final end = selection.isValid ? selection.end : _input.text.length;
    final next = _input.text.replaceRange(start, end, value);
    if (next.length > 10000) {
      toast(context, '单条消息最多 10000 字符，完整草稿已保留，请分条发送。');
      return;
    }
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  Future<void> _runTool(String action) async {
    if (action != 'favorites') setState(() => _panel = '');
    _focus.unfocus();
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
      case 'describe-image':
        await composeChatMedia(context, photo: true, streamingOverride: false);
      case 'call':
        await _voiceCallPreview();
      case 'models':
        await showChatModelPicker(context);
      case 'history':
        await _history();
      case 'favorites':
        await _favorites();
      case 'redpacket':
        await _composeWallet('redpacket');
      case 'redpacket-menu':
        await _redpacketMenu();
      case 'transfer':
        await _composeWallet('transfer');
      case 'gift':
        await _gifts();
      case 'file' || 'music':
        await _pickAttachment(action);
      case 'location':
        await _location();
      case 'contact':
        await _contact();
      case 'screen':
        await _fullPage<void>(
          '屏幕分享',
          (_) => const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '当前原生客户端暂不支持本机屏幕预览，不连接其他设备。',
              style: TextStyle(fontSize: 15, height: 1.7),
            ),
          ),
          interaction: true,
        );
    }
  }

  Future<void> _favorites() async {
    await _fullPage<void>('收藏', (_) {
      final items = _store.conversations
          .expand((chat) => chat.messages)
          .where((m) => m.bookmarked)
          .toList();
      return items.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '暂时没有收藏的消息',
                style: TextStyle(fontSize: 13, color: Color(0xff999999)),
              ),
            )
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, index) => ListTile(
                tileColor: Colors.white,
                title: Text(
                  items[index].text,
                  style: const TextStyle(fontSize: 14, height: 1.7),
                ),
                onTap: () {
                  Navigator.pop(context);
                  final chat = _store.conversations.firstWhere(
                    (chat) => chat.messages.contains(items[index]),
                  );
                  _store.selectChat(_store.conversations.indexOf(chat));
                  _locate(items[index]);
                },
              ),
            );
    }, interaction: true);
  }

  Future<void> _gifts() async {
    final gift = await _fullPage<(String, int)>(
      '礼物',
      (page) => Column(
        children: [
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              childAspectRatio: 1,
              padding: const EdgeInsets.all(16),
              mainAxisSpacing: 15,
              crossAxisSpacing: 15,
              children: [
                for (final item in [
                  ('🌹', '一枝玫瑰', 100),
                  ('☕', '一杯咖啡', 520),
                  ('⭐', '一颗星星', 1314),
                  ('🎂', '生日蛋糕', 2000),
                ])
                  InkWell(
                    onTap: () => Navigator.pop(page, (item.$2, item.$3)),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(item.$1, style: const TextStyle(fontSize: 45)),
                          const SizedBox(height: 15),
                          Text(item.$2, style: const TextStyle(fontSize: 16)),
                          const SizedBox(height: 10),
                          Text(
                            '¥${(item.$3 / 100).toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xff999999),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '角色互动 · 虚拟资金，仅保存在此设备',
              style: TextStyle(fontSize: 12, color: Color(0xff999999)),
            ),
          ),
        ],
      ),
      interaction: true,
    );
    if (gift != null && mounted)
      await showNativeSocialFinance(
        context,
        mode: widget.mode,
        kind: 'gift',
        store: _store,
        giftCents: gift.$2,
        giftName: gift.$1,
        navigate: widget.navigate,
        go: widget.go,
        onCreated: _latest,
      );
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
      if (event != null && mounted) {
        final confirmed = await _fullPage<bool>(
          kind == 'music' ? '发送音乐' : '发送文件',
          (page) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                NativeSocialMediaPreview(event: event, expanded: true),
                const SizedBox(height: 22),
                const Text(
                  '仅保存至当前角色对话，不发送给其他用户',
                  style: TextStyle(fontSize: 12, color: Color(0xff999999)),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _accent),
                    onPressed: () => Navigator.pop(page, true),
                    child: const Text('发送'),
                  ),
                ),
              ],
            ),
          ),
          interaction: true,
        );
        if (confirmed == true) _appendEvent(chat, event);
      }
    } catch (error) {
      if (mounted)
        toast(
          context,
          error is FormatException ? error.message : '附件未导入，请检查系统文件选择器后重试。',
        );
    }
  }

  Future<void> _location() async {
    final chat = _chat,
        name = TextEditingController(),
        address = TextEditingController();
    final yes = await _fullPage<bool>(
      '位置',
      (page) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 18),
              child: Text(
                '手动填写并保存位置描述，不读取手机定位。',
                style: TextStyle(fontSize: 12, color: Color(0xff999999)),
              ),
            ),
            TextField(
              controller: name,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '地点名称',
                filled: true,
                fillColor: Colors.white,
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: address,
              maxLength: 300,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '地址或位置描述',
                filled: true,
                fillColor: Colors.white,
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 45,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                onPressed: () {
                  if (name.text.trim().isNotEmpty) Navigator.pop(page, true);
                },
                child: const Text('保存到聊天'),
              ),
            ),
          ],
        ),
      ),
      interaction: true,
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
    final role = await _fullPage<Persona>(
      '选择名片',
      (page) => ListView.builder(
        itemCount: _store.personas.length,
        itemBuilder: (_, index) {
          final role = _store.personas[index];
          return ListTile(
            tileColor: Colors.white,
            leading: NativeSocialPortrait(
              mode: widget.mode,
              persona: role,
              size: 45,
              borderRadius: 6,
              store: _store,
            ),
            title: Text(role.name, style: const TextStyle(fontSize: 16)),
            subtitle: const Text(
              '本机角色名片',
              style: TextStyle(fontSize: 12, color: Color(0xff999999)),
            ),
            onTap: () => Navigator.pop(page, role),
          );
        },
      ),
      interaction: true,
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

  Future<void> _redpacketMenu() async {
    final chat = _chat;
    final selected = await _fullPage<bool>(
      '红包',
      (page) => ListView(
        children: [
          for (final item in [('红包', 'envelope'), ('拜年红包', 'gift')])
            ListTile(
              tileColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              leading: NativeSocialIcon(item.$2),
              title: Text(item.$1, style: const TextStyle(fontSize: 16)),
              onTap: () => Navigator.pop(page, true),
            ),
        ],
      ),
      interaction: true,
    );
    if (selected == true && mounted && identical(chat, _chat))
      await _composeWallet('redpacket');
  }

  Future<void> _composeWallet(String kind) => showNativeSocialFinance(
    context,
    mode: widget.mode,
    kind: kind,
    store: _store,
    navigate: widget.navigate,
    go: widget.go,
    onCreated: _latest,
  );

  Future<void> _walletDetails(Map<String, dynamic> transaction) =>
      showNativeSocialReceipt(
        context,
        transaction,
        mode: widget.mode,
        store: _store,
        navigate: widget.navigate,
        go: widget.go,
      );

  String _walletState(Map<String, dynamic> value) => switch (value['state']) {
    'received' => value['kind'] == 'redpacket' ? '已领取' : '已收款',
    'refunded' => '已退回',
    _ => value['kind'] == 'redpacket' ? '领取红包' : '待收款',
  };

  Future<void> _eventDetails(Map<String, dynamic> event) async {
    setState(() => _mediaPause++);
    final payload = event['payload'] as Map, kind = event['kind'];
    if (kind == 'contact') {
      final role = _store.personas
          .where((p) => p.id == payload['roleId'])
          .firstOrNull;
      if (role == null) {
        toast(context, '角色已不存在。');
        return;
      }
      if (widget.onRole != null) {
        widget.onRole!(role.id);
        return;
      }
      await _fullPage<void>(
        '个人名片',
        (page) => Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  NativeSocialPortrait(
                    mode: widget.mode,
                    persona: role,
                    size: 64,
                    large: true,
                    store: _store,
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          role.name,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          role.subtitle,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xff888888),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              tileColor: Colors.white,
              title: const Center(
                child: Text('发消息', style: TextStyle(color: Color(0xff576b95))),
              ),
              onTap: () {
                Navigator.pop(page);
                final chat = _store.conversations
                    .where(
                      (chat) =>
                          chat.personaId == role.id &&
                          chat.groupMembers.isEmpty,
                    )
                    .firstOrNull;
                if (chat == null)
                  _store.newChat(personaId: role.id);
                else
                  _store.selectChat(_store.conversations.indexOf(chat));
              },
            ),
            const SizedBox(height: 1),
            ListTile(
              tileColor: Colors.white,
              title: const Center(child: Text('编辑角色资料')),
              onTap: () {
                Navigator.pop(page);
                _store.persona = _store.personas.indexOf(role);
                widget.go('/characters/edit');
              },
            ),
          ],
        ),
      );
      return;
    }
    final media = const {
      'image',
      'video',
      'audio',
      'music',
      'file',
    }.contains(kind);
    await _fullPage<void>(
      payload['name']?.toString() ?? payload['label']?.toString() ?? '聊天记录',
      (page) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (media)
              Center(
                child: NativeSocialMediaPreview(event: event, expanded: true),
              )
            else
              Padding(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  kind == 'location'
                      ? '${payload['label']}\n${payload['address']}'
                      : '${payload['video'] == true ? '视频' : '语音'}通话 · ${payload['duration']} 秒',
                  style: const TextStyle(fontSize: 15, height: 1.7),
                ),
              ),
            if (media)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => openNativeChatAttachment(page, event),
                      child: const Text('系统打开'),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () => saveNativeChatAttachment(page, event),
                      child: const Text('另存'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      interaction: true,
    );
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      _availableHeight = bounds.maxHeight;
      return Material(
        color:
            UiChatAppearance().values(
                  glassEnabled: _store.prefs['毛玻璃效果'] ?? true,
                )['background'] ==
                true
            ? Colors.transparent
            : Color(_wechat ? 0xffededed : 0xffefeff1),
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
                            appearance.flag('wideChat') ? 8 : 12,
                            _wechat ? 16 : 20,
                            appearance.flag('wideChat') ? 8 : 12,
                            _wechat ? 12 : 16,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, index) =>
                              _item(_items[index], index),
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
    },
  );

  Widget _lineButton(
    String name,
    String label,
    VoidCallback? onTap, {
    double width = 36,
    double height = 40,
    double size = 27,
    bool selected = false,
  }) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xffe1e4ea) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: NativeSocialIcon(
            name,
            size: size,
            color: onTap == null
                ? const Color(0xffb3b3b3)
                : const Color(0xff202329),
          ),
        ),
      ),
    ),
  );

  Widget _headerTitle() => GestureDetector(
    onLongPress: _history,
    child: InkWell(
      onTap: widget.onInfo,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: _wechat
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            _chat.groupMembers.isEmpty ? _speaker(null).name : _chat.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: _wechat ? FontWeight.w500 : FontWeight.w400,
              color: const Color(0xff191919),
            ),
          ),
          if (!_wechat)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  const Text(
                    '●',
                    style: TextStyle(fontSize: 10, color: Color(0xff00ce78)),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _store.streaming
                        ? '正在回复…'
                        : _chat.groupMembers.isEmpty
                        ? '当前对话'
                        : _chat.groupKind == 'channel'
                        ? '频道'
                        : '群聊',
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.45,
                      color: Color(0xff747474),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );

  Widget _header() {
    final back = _lineButton(
      'chevron-left',
      '返回',
      () {
        if (_panel.isNotEmpty) {
          setState(() => _panel = '');
        } else {
          _focus.unfocus();
          widget.onBack();
        }
      },
      width: 32,
      height: 44,
      size: 24,
    );
    final more = _lineButton(
      _wechat ? 'more' : 'menu',
      '聊天信息',
      widget.onInfo,
      width: 36,
      height: 44,
      size: 25,
    );
    return Container(
      key: const ValueKey('social-chat-header'),
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top,
        left: 12,
        right: 12,
      ),
      color: Color(_wechat ? 0xffededed : 0xffefeff1),
      child: SizedBox(
        width: double.infinity,
        height: _wechat ? 52 : 56,
        child: _wechat
            ? Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(left: 0, child: back),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 44),
                    child: _headerTitle(),
                  ),
                  Positioned(right: 0, child: more),
                ],
              )
            : Row(
                children: [
                  back,
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _headerTitle(),
                    ),
                  ),
                  more,
                ],
              ),
      ),
    );
  }

  Widget _composer() {
    final count = _chat.queuedMessages.length;
    final hasText = _input.text.trim().isNotEmpty;
    final input = TextField(
      key: const ValueKey('social-chat-input'),
      controller: _input,
      focusNode: _focus,
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      inputFormatters: [
        if (_input.text.length <= 10000)
          LengthLimitingTextInputFormatter(10000),
      ],
      style: TextStyle(
        fontSize: 16,
        height: 22 / 16,
        fontFamily: appearance.fontFamily('inputFont'),
        color: appearance.textColor('inputText'),
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        hintText: '',
        contentPadding: EdgeInsets.symmetric(
          horizontal: _wechat ? 8 : 10,
          vertical: 8,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_wechat ? 4 : 7),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_wechat ? 4 : 7),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_wechat ? 4 : 7),
          borderSide: BorderSide.none,
        ),
      ),
    );
    final send = SizedBox(
      width: _wechat ? 53 : 54,
      height: _wechat ? 34 : 35,
      child: TextButton(
        key: const ValueKey('social-send'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          backgroundColor: _store.streaming || hasText
              ? Color(_wechat ? 0xff07c160 : 0xff009dff)
              : const Color(0xffc5e5fd),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_wechat ? 4 : 7),
          ),
        ),
        onPressed: _store.streaming
            ? _store.stop
            : hasText
            ? _send
            : null,
        child: Text(
          _store.streaming ? '停止' : '发送',
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
    return Container(
      key: const ValueKey('social-chat-composer'),
      padding: EdgeInsets.fromLTRB(
        _wechat ? 8 : 12,
        _wechat ? 5 : 7,
        _wechat ? 8 : 12,
        _wechat ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: Color(_wechat ? 0xfff7f7f7 : 0xfff2f3f5),
        border: const Border(
          top: BorderSide(color: Color(0xffe5e6e8), width: .5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_chat.confirmBeforeReply || count > 0)
            Row(
              children: [
                Expanded(
                  child: Text(
                    count > 0 ? '$count 条待发送' : '分条输入，确认后统一回复',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (count > 0)
                  TextButton(
                    onPressed: _store.streaming ? null : _discard,
                    child: const Text('清空'),
                  ),
                TextButton(
                  onPressed: count == 0 || _store.streaming ? null : _confirm,
                  child: const Text('确认发送'),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_wechat) ...[
                _lineButton(_voiceMode ? 'keyboard' : 'voice', '语音识别', () {
                  _focus.unfocus();
                  setState(() {
                    _panel = '';
                    _voiceMode = !_voiceMode;
                  });
                }, width: 28),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: _voiceMode && _wechat
                    ? GestureDetector(
                        onTap: () => _runTool('speech'),
                        onLongPress: () => _runTool('speech'),
                        child: Container(
                          height: 39,
                          decoration: BoxDecoration(
                            color: const Color(0xfff5f5f5),
                            border: Border.all(color: const Color(0xffd5d5d5)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            '按住 说话',
                            style: TextStyle(fontSize: 15),
                          ),
                        ),
                      )
                    : ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: _wechat ? 39 : 38,
                          maxHeight: 100,
                        ),
                        child: input,
                      ),
              ),
              SizedBox(width: _wechat ? 7 : 8),
              if (_wechat) ...[
                _lineButton(
                  'smile',
                  '表情包',
                  () => _togglePanel('emoji'),
                  width: 28,
                  selected: _panel == 'emoji',
                ),
                const SizedBox(width: 7),
                if (hasText || _store.streaming)
                  send
                else
                  _lineButton(
                    'plus-circle',
                    '更多功能',
                    _tools,
                    width: 28,
                    selected: _panel == 'more',
                  ),
              ] else
                send,
            ],
          ),
          if (!_wechat)
            SizedBox(
              height: 47,
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final tool in [
                      ('mic', '语音识别', 'speech'),
                      ('image', '相册', 'album'),
                      ('camera', '拍摄照片', 'camera'),
                      ('sparkles', '模型助手', 'models'),
                      ('smile', '表情包', 'emoji'),
                      ('plus-circle', '更多功能', 'more'),
                    ])
                      _lineButton(
                        tool.$1,
                        tool.$2,
                        () => tool.$3 == 'emoji' || tool.$3 == 'more'
                            ? _togglePanel(tool.$3)
                            : _runTool(tool.$3),
                        width: MediaQuery.sizeOf(context).width < 330 ? 34 : 40,
                        height: 42,
                        selected: _panel == tool.$3,
                      ),
                  ],
                ),
              ),
            ),
          if (_panel.isNotEmpty)
            Container(
              padding: EdgeInsets.only(top: _wechat ? 16 : 8),
              margin: EdgeInsets.only(top: _wechat ? 5 : 0),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xffe6e7eb))),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      (_availableHeight -
                              MediaQuery.paddingOf(context).top -
                              56 -
                              (_wechat ? 120 : 170) -
                              (_chat.confirmBeforeReply || count > 0 ? 48 : 0))
                          .clamp(0, 350),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SocialChatInlinePanel(
                        key: ValueKey(
                          '${widget.mode.name}-$_panel-${_chat.id}',
                        ),
                        mode: widget.mode,
                        kind: _panel,
                        store: _store,
                        onAction: _runTool,
                        onEmoji: _insertEmoji,
                        onSticker: (id) {
                          if (!_store.send(
                            _store.stickerFor(id)?.name ?? '',
                            kind: 'sticker',
                            stickerId: id,
                            streamingOverride: false,
                          ))
                            toast(context, _store.lastError ?? '当前无法发送');
                          else
                            _latest();
                        },
                        onManage: () => widget.go('/stickers'),
                      ),
                      if (_panel == 'more')
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const OpenPluginChatButton(),
                            TextButton(
                              onPressed: () => _runTool('history'),
                              child: const Text(
                                '查找聊天记录',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            if (_wechat) ...[
                              TextButton(
                                onPressed: () => _runTool('models'),
                                child: const Text(
                                  '模型助手',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: () => _runTool('call'),
                                child: const Text(
                                  '语音通话',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _item(_SocialChatItem item, int index) {
    final key = _keys.putIfAbsent(item.id, () => GlobalKey());
    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: _store.compact ? 12 : 21),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (index == 0 ||
              item.created.difference(_items[index - 1].created).inMinutes >= 5)
            Padding(
              padding: const EdgeInsets.only(bottom: 23),
              child: Center(
                child: Text(
                  _date(item.created),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffa1a1a1),
                  ),
                ),
              ),
            ),
          item.message != null ? _message(item.message!) : _attachment(item),
        ],
      ),
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
    child: NativeSocialPortrait(
      mode: widget.mode,
      persona: role,
      user: user,
      store: _store,
    ),
  );

  bool get _customSurface =>
      !(UiChatAppearance().values(
                glassEnabled: _store.prefs['毛玻璃效果'] ?? true,
              )['defaultBubbleSurface'] ==
              true &&
          glassPreferences.userBlur == 6 &&
          glassPreferences.assistantBlur == 6);

  Widget _nativeRow({
    required bool user,
    required Persona role,
    required Widget child,
    bool full = false,
    bool side = false,
  }) => LayoutBuilder(
    builder: (context, bounds) {
      final avatar = appearance.flag('avatars') ? _avatar(user, role) : null;
      if (full && !user)
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (avatar != null)
              Align(alignment: Alignment.centerLeft, child: avatar),
            if (avatar != null) const SizedBox(height: 12),
            child,
          ],
        );
      final width = (bounds.maxWidth - (side ? 48 : 96)).clamp(
        80.0,
        bounds.maxWidth,
      );
      return Row(
        mainAxisAlignment: user
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!user && avatar != null) ...[avatar, const SizedBox(width: 10)],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: child,
            ),
          ),
          if (user && avatar != null) ...[const SizedBox(width: 10), avatar],
        ],
      );
    },
  );

  Widget _typedBody(Message message) {
    if (message.kind == 'sticker') {
      final data = _store.stickerFor(message.stickerId)?.data;
      return data == null
          ? Text('[表情包：${message.text}]')
          : Image.memory(
              base64Decode(data.split(',').last),
              width: 140,
              height: 140,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Text('[表情包：${message.text}]'),
            );
    }
    if (message.kind == 'voice')
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          leading: const NativeSocialIcon('mic', size: 22),
          title: Text(
            '语音 · ${message.described ? '文字描述' : '识别转写'}',
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: const Text('查看内容', style: TextStyle(fontSize: 10)),
          children: [
            Text(
              message.text,
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
          ],
        ),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.imageData != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 250),
            child: Image.memory(
              base64Decode(message.imageData!.split(',').last),
              frameBuilder: (_, child, frame, _) {
                if (frame != null && _follow) _bottom();
                return child;
              },
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('图片无法显示'),
            ),
          )
        else
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NativeSocialIcon('image', size: 22),
              SizedBox(width: 7),
              Text('照片 · 内容描述', style: TextStyle(fontSize: 12)),
            ],
          ),
        const SizedBox(height: 7),
        Text(message.text),
      ],
    );
  }

  Widget _message(Message message) {
    final role = _speaker(message.authorId), custom = _customSurface;
    final layout = appearance.text('assistantBubbleLayout');
    final media = _messageAttachment(message);
    final body = message.kind == 'text'
        ? Text(
            message.text.isNotEmpty
                ? message.text
                : message.status == 'cancelled'
                ? '已停止生成'
                : '未收到回复',
            style: custom
                ? chatMessageStyle(context, message.user, size: 16)
                : null,
          )
        : _typedBody(message);
    final content = GestureDetector(
      onTap: media == null ? null : () => _eventDetails(media),
      onHorizontalDragStart: media == null ? null : (_) {},
      onLongPress: () => _messageMenu(message),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: message.user
            ? CrossAxisAlignment.end
            : custom && layout != 'centered'
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          if (!message.user && _chat.groupMembers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                role.name,
                style: const TextStyle(fontSize: 11, color: Color(0xff999999)),
              ),
            ),
          if (message.kind == 'sticker')
            body
          else
            SocialChatSurface(
              key: ValueKey(
                'social-message-${message.created.microsecondsSinceEpoch}',
              ),
              mode: widget.mode,
              user: message.user,
              custom: custom,
              child: body,
            ),
          if (message.pluginCards.isNotEmpty)
            CompanionMessageCards(message: message),
          if (message.contextNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                message.contextNotice!,
                style: const TextStyle(fontSize: 11, color: Color(0xff888888)),
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
                      color: message.status == 'failed'
                          ? const Color(0xffd94c45)
                          : const Color(0xff888888),
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
                  icon: const NativeSocialIcon('close', size: 15),
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
                style: const TextStyle(fontSize: 10, color: Color(0xff888888)),
              ),
            ),
          if (message.bookmarked)
            NativeSocialIcon('star', size: 13, color: _accent),
        ],
      ),
    );
    return _nativeRow(
      user: message.user,
      role: role,
      child: content,
      full: custom && layout == 'full',
      side: custom && layout == 'side',
    );
  }

  Widget _attachment(_SocialChatItem item) {
    final data = item.data!,
        role = _speaker(item.wallet ? item.data!['roleId'] : null);
    final payload = item.wallet ? data : data['payload'] as Map;
    Widget body;
    if (item.wallet) {
      final red = data['kind'] == 'redpacket',
          resolved = data['state'] != 'pending';
      body = Container(
        width: 210,
        decoration: BoxDecoration(
          color: resolved
              ? Color(_wechat ? 0xfff9dcae : 0xffefd4b0)
              : Color(
                  _wechat
                      ? red
                            ? 0xfffa9d3b
                            : 0xfff5a142
                      : 0xfff5ac4d,
                ),
          borderRadius: BorderRadius.circular(_wechat ? 5 : 10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 16),
              child: Row(
                children: [
                  NativeSocialIcon(
                    red
                        ? 'envelope'
                        : data['kind'] == 'gift'
                        ? 'gift'
                        : 'transfer',
                    size: 32,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          red
                              ? data['note']?.toString().isNotEmpty == true
                                    ? data['note']
                                    : '恭喜发财，大吉大利'
                              : '¥${((data['cents'] as int) / 100).toStringAsFixed(2)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: red ? 15 : 18,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _walletState(data),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0x35ffffff))),
              ),
              child: Text(
                '${_walletTitle(data['kind'])} · 角色虚拟钱包',
                style: const TextStyle(fontSize: 10, color: Color(0xfffffde8)),
              ),
            ),
          ],
        ),
      );
    } else if (const {
      'image',
      'video',
      'audio',
      'music',
      'file',
    }.contains(data['kind'])) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: NativeSocialMediaPreview(
          key: ValueKey('social-inline-media-${data['id']}'),
          event: data,
          active: widget.active,
          pauseToken: _mediaPause,
          onReady: () {
            if (_follow) _bottom();
          },
        ),
      );
    } else if (data['kind'] == 'location') {
      body = Container(
        width: 240,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Text(
                payload['label'],
                style: const TextStyle(fontSize: 15),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 12, 12),
              child: Text(
                payload['address'],
                style: const TextStyle(fontSize: 11, color: Color(0xff999999)),
              ),
            ),
            Container(
              height: 115,
              color: const Color(0xffe6ecdf),
              alignment: Alignment.center,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  NativeSocialIcon('pin', size: 34, color: Color(0xffef6c58)),
                  SizedBox(width: 9),
                  Text(
                    '位置描述',
                    style: TextStyle(fontSize: 12, color: Color(0xff687b66)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (data['kind'] == 'contact') {
      final contact = _store.personas
          .where((p) => p.id == payload['roleId'])
          .firstOrNull;
      body = Container(
        width: 230,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (contact != null)
                  NativeSocialPortrait(
                    mode: widget.mode,
                    persona: contact,
                    size: 40,
                    store: _store,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    payload['name'],
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '个人名片',
                style: TextStyle(fontSize: 10, color: Color(0xff999999)),
              ),
            ),
          ],
        ),
      );
    } else {
      body = Container(
        padding: const EdgeInsets.all(12),
        color: Colors.white,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NativeSocialIcon(
              payload['video'] == true ? 'video' : 'phone',
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              '${payload['video'] == true ? '视频' : '语音'}通话 ${payload['duration']} 秒',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
      );
    }
    final content = GestureDetector(
      onHorizontalDragStart: (_) {},
      onTap: () => item.wallet ? _walletDetails(data) : _eventDetails(data),
      onLongPress: () => _hideItem(item),
      child: body,
    );
    return _nativeRow(user: item.user, role: role, child: content);
  }

  static String _date(DateTime time) {
    final now = DateTime.now();
    final today =
        now.year == time.year && now.month == time.month && now.day == time.day;
    return '${today ? '今天' : '${time.month}月${time.day}日'} ${_time(time)}';
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
  'redpacket' => '红包',
  'gift' => '礼物',
  _ => '转账',
};
