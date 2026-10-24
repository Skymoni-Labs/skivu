import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'appearance.dart';
import 'appearance_settings.dart';
import 'chat_controls.dart';
import 'legacy_social_migration.dart';
import 'native_social_chat.dart';
import 'native_social_extras.dart';
import 'native_social_icons.dart';
import 'native_social_details.dart';
import 'native_social_portrait.dart';
import 'plugin_edge_controls.dart';
import 'social_activity.dart';
import 'state.dart';
import 'ui_host_binding.dart';
import 'ui_plugins.dart';
import 'virtual_wallet.dart';
import 'wallpaper.dart';

/// Flutter-only social shell. All pages share the original local stores.
class NativeSocialPage extends StatefulWidget {
  const NativeSocialPage({
    super.key,
    required this.go,
    required this.openNavigation,
    required this.openWorkspace,
    this.store,
    this.backBlocked,
  });
  final ValueChanged<String> go;
  final VoidCallback openNavigation, openWorkspace;
  final DemoStore? store;
  final bool Function()? backBlocked;
  @override
  State<NativeSocialPage> createState() => _NativeSocialPageState();
}

class _NativeSocialPageState extends State<NativeSocialPage> {
  late final DemoStore _store = widget.store ?? demo;
  late final UiHostBinding _binding = UiHostBinding(_store);
  late final PageController _pages = PageController(
    initialPage: uiPlugins.tab.clamp(0, 3),
  );
  late int _revision = uiPlugins.homeRevision, _tab = uiPlugins.tab.clamp(0, 3);
  late ChatUiMode _mode = uiPlugins.mode;
  late String _page = uiPlugins.conversationVisible ? 'chat' : 'home';
  final List<(String, String?)> _trail = [];
  String? _contactId;
  Message? _locate;
  String _query = '';
  String _contactQuery = '', _inboxQuery = '', _contactFilter = 'friends';
  double _viewHeight = 800;
  bool _searchChatOnly = false, _edgeGesture = false;
  double _backDrag = 0;
  bool _keepChat = uiPlugins.conversationVisible;
  String? _replyChat;
  bool get _wx => _mode == ChatUiMode.wechat;
  Color get _accent => _wx ? const Color(0xff07c160) : const Color(0xff0099ff);
  Conversation get _chat => _binding.selected;
  Persona? _role(String? id) =>
      _store.personas.where((p) => p.id == id).firstOrNull;
  List<String> get _tabs =>
      _wx ? ['微信', '通讯录', '发现', '我'] : ['消息', '频道', '联系人', '动态'];

  @override
  void initState() {
    super.initState();
    _store.addListener(_refresh);
    appearance.addListener(_refresh);
    socialActivity.addListener(_refresh);
    virtualWallet.addListener(_refresh);
    uiPlugins.addListener(_preferences);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(legacySocialMigration.ensure(_mode));
    });
  }

  @override
  void dispose() {
    _store.removeListener(_refresh);
    appearance.removeListener(_refresh);
    socialActivity.removeListener(_refresh);
    virtualWallet.removeListener(_refresh);
    uiPlugins.removeListener(_preferences);
    _pages.dispose();
    super.dispose();
  }

  void _refresh() {
    if (_store.streaming) {
      _replyChat = _chat.id;
    } else if (_replyChat != null) {
      final completed =
          _replyChat == _chat.id &&
          _chat.replyReminder &&
          !_chat.muted &&
          _chat.messages.lastOrNull?.status == 'complete' &&
          _chat.messages.lastOrNull?.user == false;
      _replyChat = null;
      if (completed) {
        final label = '${_role(_chat.personaId)?.name ?? _chat.title}回复了你';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _notice(label);
        });
      }
    }
    if (mounted) setState(() {});
  }

  void _preferences() {
    if (!mounted) return;
    if (_revision != uiPlugins.homeRevision || _mode != uiPlugins.mode) {
      _revision = uiPlugins.homeRevision;
      _mode = uiPlugins.mode;
      _trail.clear();
      _tab = uiPlugins.tab.clamp(0, 3);
      _page = 'home';
      _restoreTab();
      unawaited(legacySocialMigration.ensure(_mode));
    } else if (uiPlugins.conversationVisible && _page != 'chat') {
      _page = 'chat';
      _keepChat = true;
    }
    setState(() {});
  }

  void _restoreTab() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _pages.hasClients) _pages.jumpToPage(_tab);
  });
  void _notice(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _navigate(String target, {String? contact}) {
    FocusScope.of(context).unfocus();
    if (target == 'home') {
      _trail.clear();
      uiPlugins.conversationVisible = false;
      setState(() => _page = 'home');
      _restoreTab();
      return;
    }
    if (_page != target || _contactId != contact)
      _trail.add((_page, _contactId));
    uiPlugins.conversationVisible = target == 'chat';
    setState(() {
      _page = target;
      if (target == 'chat') _keepChat = true;
      _contactId = contact;
    });
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_trail.isEmpty) {
      _navigate('home');
      return;
    }
    final prior = _trail.removeLast();
    uiPlugins.conversationVisible = prior.$1 == 'chat';
    setState(() {
      _page = prior.$1;
      _contactId = prior.$2;
      _locate = null;
    });
    if (_page == 'home') _restoreTab();
  }

  void _openChat(Conversation chat, {Message? locate}) {
    if (!SocialChatBinding(_store).activate(chat.id)) return;
    _locate = locate;
    _navigate('chat');
  }

  Future<void> _chooseChat(Persona role) async {
    await _showRootPage<void>(
      role.name,
      (route) => ListView(
        padding: const EdgeInsets.only(bottom: 25),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${_store.conversationsFor(role.id).where((c) => c.groupMembers.isEmpty).length} 段独立对话 · 共用角色卡，记录各自保存',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xff888888),
                height: 1.8,
              ),
            ),
          ),
          for (final c
              in _store
                  .conversationsFor(role.id)
                  .where((c) => c.groupMembers.isEmpty))
            Material(
              color: Colors.white,
              child: InkWell(
                onTap: () {
                  Navigator.pop(route);
                  _openChat(c);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.title, style: const TextStyle(fontSize: 16)),
                            const SizedBox(height: 5),
                            Text(
                              _preview(c),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xff999999),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (c.id == _chat.id)
                        NativeSocialIcon('check', color: _accent, size: 22),
                    ],
                  ),
                ),
              ),
            ),
          _menuRow('新建独立对话', 'plus', () {
            Navigator.pop(route);
            _store.newChat(personaId: role.id);
            _openChat(_chat);
          }),
        ],
      ),
    );
  }

  int _unread({bool channel = false}) => SocialChatBinding(_store).inbox
      .where(
        (c) =>
            !c.muted &&
            (channel
                ? c.groupKind == 'channel'
                : _wx || c.groupKind != 'channel'),
      )
      .fold(0, (n, c) => n + c.unreadCount);
  Widget _badge(int count, {bool dot = false}) => count == 0
      ? const SizedBox.shrink()
      : Container(
          padding: EdgeInsets.symmetric(horizontal: dot ? 0 : 5),
          constraints: BoxConstraints(
            minWidth: dot ? 8 : 19,
            minHeight: dot ? 8 : 19,
          ),
          decoration: BoxDecoration(
            color: const Color(0xfffa5151),
            borderRadius: BorderRadius.circular(12),
          ),
          child: dot
              ? null
              : Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
        );
  String _preview(Conversation c) {
    if (c.draft.isNotEmpty) return '[草稿] ${c.draft}';
    if (c.messages.lastOrNull?.status == 'pending') return '对方正在输入中…';
    return _latestActivity(c).text;
  }

  ({DateTime? at, String text}) _latestActivity(Conversation c) {
    var time = c.messages.lastOrNull?.created;
    var text = c.messages.lastOrNull?.text ?? '还没有消息';
    for (final e in c.interactions.where(
      (e) => !c.hiddenInteractions.contains(e['id']),
    )) {
      final at = DateTime.tryParse('${e['created']}');
      if (at != null && (time == null || at.isAfter(time))) {
        time = at;
        text = switch (e['kind']) {
          'image' || 'photo' => '[图片]',
          'voice' || 'audio' => '[语音]',
          'music' => '[音乐]',
          'call' => '[通话]',
          'video' => '[视频]',
          'file' => '[文件]',
          'contact' => '[角色名片]',
          'location' => '[位置]',
          _ => '[互动消息]',
        };
      }
    }
    final transactions = virtualWallet.snapshot()['transactions'] as List;
    for (final e in transactions.whereType<Map>().where(
      (e) => e['chatId'] == c.id,
    )) {
      final at = DateTime.tryParse('${e['created']}');
      if (at != null &&
          (time == null || at.isAfter(time)) &&
          !c.hiddenInteractions.contains(e['id']) &&
          (c.interactionsClearedAt == null ||
              at.isAfter(c.interactionsClearedAt!))) {
        time = at;
        text = switch (e['kind']) {
          'redpacket' => '[虚拟红包]',
          'gift' => '[虚拟礼物]',
          _ => '[虚拟转账]',
        };
      }
    }
    return (at: time, text: text);
  }

  Widget _face(Conversation c) {
    final roles = c.groupMembers
        .map(_role)
        .whereType<Persona>()
        .take(4)
        .toList();
    final face = roles.isEmpty
        ? (_role(c.personaId) == null
              ? const Icon(Icons.person)
              : NativeSocialPortrait(
                  mode: _mode,
                  persona: _role(c.personaId)!,
                  size: _wx ? 44 : 50,
                ))
        : Container(
            width: _wx ? 44 : 50,
            height: _wx ? 44 : 50,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xffdddfe3),
              borderRadius: BorderRadius.circular(_wx ? 5 : 25),
            ),
            child: GridView.count(
              crossAxisCount: 2,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              children: roles
                  .map(
                    (p) => Padding(
                      padding: const EdgeInsets.all(1),
                      child: NativeSocialPortrait(
                        mode: _mode,
                        persona: p,
                        size: 20,
                        square: true,
                      ),
                    ),
                  )
                  .toList(),
            ),
          );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        Positioned(
          right: -5,
          top: -5,
          child: _badge(c.unreadCount, dot: c.muted),
        ),
      ],
    );
  }

  Widget _inbox(bool channel) {
    final chats = SocialChatBinding(_store).inbox
        .where(
          (c) =>
              (_wx ||
                  (channel
                      ? c.groupKind == 'channel'
                      : c.groupKind != 'channel')) &&
              ('${_role(c.personaId)?.name ?? ''} ${c.title}')
                  .toLowerCase()
                  .contains(_inboxQuery.toLowerCase()),
        )
        .toList();
    final activity = {for (final c in chats) c.id: _latestActivity(c)};
    chats.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return (activity[b.id]!.at ?? DateTime(1970)).compareTo(
        activity[a.id]!.at ?? DateTime(1970),
      );
    });
    return Column(
      children: [
        if (!_wx && !channel)
          _NativeSocialRootSearch(
            key: const ValueKey('inbox-search'),
            wechat: false,
            placeholder: '搜索',
            onChanged: (v) => setState(() => _inboxQuery = v),
          ),
        Expanded(
          child: Material(
            color: Colors.white,
            child: ListView.builder(
              key: PageStorageKey('native-inbox-${_mode.name}-$channel'),
              padding: EdgeInsets.zero,
              itemCount: chats.isEmpty ? 1 : chats.length,
              itemBuilder: (context, index) {
                if (chats.isEmpty)
                  return _empty(
                    _inboxQuery.isNotEmpty ? '没有匹配的会话' : '还没有对话，点击右上角选择角色新建。',
                  );
                final c = chats[index],
                    role = _role(c.personaId),
                    at = activity[c.id]!.at;
                return Material(
                  color: c.pinned
                      ? (_wx
                            ? const Color(0xffededed)
                            : const Color(0xfff0f1f9))
                      : Colors.white,
                  child: InkWell(
                    onTap: () => _openChat(c),
                    onLongPress: () => _chatMenu(c),
                    child: SizedBox(
                      height: _wx ? 70 : 74,
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                _face(c),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              c.groupMembers.isNotEmpty
                                                  ? c.title
                                                  : role?.name ?? c.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w400,
                                                color: Color(0xff191919),
                                              ),
                                            ),
                                          ),
                                          if (c.groupMembers.isEmpty) ...[
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                c.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Color(0xff999999),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        _preview(c),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: _wx ? 14 : 13,
                                          color: _wx
                                              ? const Color(0xffa1a1a1)
                                              : const Color(0xff8b8e97),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 43,
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        at == null
                                            ? ''
                                            : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _wx
                                              ? const Color(0xffb2b2b2)
                                              : const Color(0xff9c9ea5),
                                        ),
                                      ),
                                      if (c.muted)
                                        const NativeSocialIcon(
                                          'bell-off',
                                          size: 14,
                                          color: Color(0xffb2b2b2),
                                        )
                                      else if (c.id == _chat.id)
                                        Text(
                                          '●',
                                          style: const TextStyle(
                                            color: Color(0xff07c160),
                                            fontSize: 9,
                                          ),
                                        )
                                      else
                                        const SizedBox(height: 12),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_wx)
                            const Positioned(
                              left: 72,
                              right: 0,
                              bottom: 0,
                              child: Divider(
                                height: .5,
                                thickness: .5,
                                color: Color(0xffececec),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuRow(
    String title,
    String icon,
    VoidCallback action, {
    String? note,
    bool divider = false,
    Color color = const Color(0xff586e91),
  }) => Material(
    color: Colors.white,
    child: InkWell(
      onTap: action,
      child: CustomPaint(
        foregroundPainter: divider ? const _SocialMenuSeparator() : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 55),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
          child: Row(
            children: [
              NativeSocialIcon(icon, size: 22, color: color),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xff191919),
                  ),
                ),
              ),
              if (note != null)
                Flexible(
                  child: Text(
                    note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff999999),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              const NativeSocialIcon(
                'right',
                size: 16,
                color: Color(0xffb2b2b2),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _contactRow(Persona role) => Material(
    color: Colors.white,
    child: InkWell(
      onTap: () => _navigate('contact', contact: role.id),
      child: SizedBox(
        height: 59,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  NativeSocialPortrait(mode: _mode, persona: role, size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      role.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xff191919),
                      ),
                    ),
                  ),
                  if (!_wx)
                    const NativeSocialIcon(
                      'right',
                      size: 16,
                      color: Color(0xffb2b2b2),
                    ),
                ],
              ),
            ),
            const Positioned(
              left: 68,
              right: 0,
              bottom: 0,
              child: Divider(
                height: .5,
                thickness: .5,
                color: Color(0xffe8e8e8),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  String _letter(Persona p) {
    final first = p.name.isEmpty ? '#' : p.name.characters.first;
    if (RegExp('[A-Za-z]').hasMatch(first)) return first.toUpperCase();
    return const {'程': 'C', '林': 'L', '宁': 'N', '许': 'X'}[first] ?? '#';
  }

  Widget _section(
    String text, {
    EdgeInsets padding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 7,
    ),
  }) => Container(
    width: double.infinity,
    padding: padding,
    color: const Color(0xffededed),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xff888888)),
    ),
  );

  Widget _contacts() {
    final roles = _store.personas
        .where(
          (p) => p.name.toLowerCase().contains(_contactQuery.toLowerCase()),
        )
        .toList();
    if (_wx)
      roles.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    final grouped = <String, List<Persona>>{};
    for (final p in roles) {
      (grouped[_letter(p)] ??= []).add(p);
    }
    final letters = grouped.keys.toList()..sort();
    final groups = _store.visibleConversations
        .where(
          (c) =>
              c.groupMembers.isNotEmpty &&
              c.groupKind != 'channel' &&
              c.title.toLowerCase().contains(_contactQuery.toLowerCase()),
        )
        .toList();
    return Stack(
      children: [
        ListView(
          key: PageStorageKey('native-contacts-${_mode.name}'),
          padding: EdgeInsets.zero,
          children: [
            _NativeSocialRootSearch(
              key: ValueKey('contacts-search-${_mode.name}'),
              wechat: _wx,
              placeholder: _wx ? '搜索' : '搜索联系人',
              onChanged: (v) => setState(() => _contactQuery = v),
            ),
            if (_wx) ...[
              for (final item in [
                ('新的朋友', 'users', const Color(0xfffa9d3b)),
                ('群聊', 'chat', const Color(0xff07c160)),
                ('标签', 'box', const Color(0xff2782d7)),
                ('公众号', 'book', const Color(0xff2782d7)),
              ])
                Material(
                  color: Colors.white,
                  child: InkWell(
                    onTap: () => widget.go('/characters'),
                    child: SizedBox(
                      height: 59,
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: item.$3,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Center(
                                    child: NativeSocialIcon(
                                      item.$2,
                                      color: Colors.white,
                                      size: 23,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  item.$1,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Color(0xff191919),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Positioned(
                            left: 68,
                            right: 0,
                            bottom: 0,
                            child: Divider(
                              height: .5,
                              thickness: .5,
                              color: Color(0xffe8e8e8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              _section('我的朋友'),
              for (final letter in letters) ...[
                _section(letter),
                for (final p in grouped[letter]!) _contactRow(p),
              ],
              if (roles.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(30),
                  child: Text(
                    '没有找到联系人',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xff999999)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(23),
                child: Text(
                  '${roles.length} 位联系人',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xff999999),
                  ),
                ),
              ),
            ] else ...[
              ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 13, 18, 6),
                  child: Row(
                    children: [
                      for (final tab in [
                        ('friends', '好友'),
                        ('groups', '群聊'),
                        ('requests', '新朋友'),
                        ('calls', '通话'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 24),
                          child: InkWell(
                            onTap: () {
                              if (tab.$1 == 'requests') {
                                widget.go('/characters');
                                return;
                              }
                              if (tab.$1 == 'calls') {
                                _navigate('calls');
                                return;
                              }
                              setState(() => _contactFilter = tab.$1);
                            },
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(1, 3, 1, 7),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: _contactFilter == tab.$1
                                        ? const Color(0xff1eabf4)
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                              child: Text(
                                tab.$2,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: _contactFilter == tab.$1
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: _contactFilter == tab.$1
                                      ? const Color(0xff0099ff)
                                      : const Color(0xff8494a1),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 17,
                ),
                child: Row(
                  children: [
                    const NativeSocialIcon('down', size: 14),
                    const SizedBox(width: 7),
                    Text(
                      _contactFilter == 'groups' ? '我的群聊' : '特别关心与我的朋友',
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_contactFilter == 'groups' ? groups.length : roles.length}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xff555555),
                      ),
                    ),
                  ],
                ),
              ),
              if (_contactFilter == 'groups') ...[
                for (final c in groups) _groupInboxRow(c),
                _menuRow('＋ 发起群聊', 'users', () => _groupConfig()),
              ] else ...[
                for (final p in roles) _contactRow(p),
                if (roles.isEmpty) _empty('没有找到联系人'),
              ],
            ],
          ],
        ),
        if (_wx)
          Positioned(
            right: 7,
            top: (390 - MediaQuery.paddingOf(context).top - 52).clamp(
              80.0,
              _viewHeight - 220,
            ),
            child: IgnorePointer(
              child: Column(
                children: [
                  for (final x in ['↑', '☆', 'C', 'L', 'N', 'S', 'X', '#'])
                    SizedBox(
                      height: 22,
                      child: Text(
                        x,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xff555555),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.all(30),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 14,
        color: Color(0xff999999),
        height: 1.7,
      ),
    ),
  );

  Widget _groupInboxRow(Conversation c) => Material(
    color: Colors.white,
    child: InkWell(
      onTap: () => _openChat(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _face(c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.title,
                    style: const TextStyle(fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${c.groupMembers.length + 1} 位成员',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff999999),
                    ),
                  ),
                ],
              ),
            ),
            const NativeSocialIcon('right', size: 16, color: Color(0xffb2b2b2)),
          ],
        ),
      ),
    ),
  );

  Widget _channels() => ListView(
    key: const PageStorageKey('native-channels'),
    padding: EdgeInsets.zero,
    children: [
      _section('我的频道'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Text(
          '与多个角色在同一频道交流，记录独立保存。',
          style: const TextStyle(fontSize: 13, color: Color(0xff888888)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SizedBox(
          height: 45,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xff009dff),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            onPressed: () => _groupConfig(null, true),
            child: const Text(
              '创建频道',
              style: TextStyle(fontSize: 16, color: Colors.white),
            ),
          ),
        ),
      ),
      for (final c in _store.visibleConversations.where(
        (c) => c.groupKind == 'channel',
      ))
        _groupInboxRow(c),
      if (!_store.visibleConversations.any((c) => c.groupKind == 'channel'))
        _empty('还没有频道'),
    ],
  );

  Widget _discover() => ListView(
    key: PageStorageKey('native-discover-${_mode.name}'),
    padding: EdgeInsets.zero,
    children: [
      if (_wx)
        _menuRow(
          '朋友圈',
          'compass',
          () => _navigate('moments'),
          color: const Color(0xff2782d7),
        )
      else ...[
        _menuRow(
          '好友动态',
          'image',
          () => _navigate('moments'),
          note: socialActivity.feed('qq').isEmpty
              ? '还没有动态'
              : '${socialActivity.feed('qq').length} 条动态',
          color: const Color(0xff359cde),
        ),
        _menuRow(
          '我的空间',
          'star',
          () => _navigate('moments'),
          note: '记录生活',
          color: const Color(0xffe5af4d),
        ),
        const SizedBox(height: 8),
        _menuRow(
          '相册',
          'image',
          () => _navigate('albums'),
          color: const Color(0xff52b2c3),
        ),
        _menuRow(
          '收藏',
          'star',
          () => _navigate('favorites'),
          color: const Color(0xffd6ad69),
        ),
        _menuRow(
          '文件',
          'folder',
          () => _navigate('files'),
          color: const Color(0xff71a8cf),
        ),
        _menuRow(
          '通话记录',
          'phone',
          () => _navigate('calls'),
          color: const Color(0xff719fd0),
        ),
        const SizedBox(height: 8),
        _menuRow(
          '小程序',
          'grid',
          () => _navigate('miniapps'),
          color: const Color(0xff5a9eb5),
        ),
        _menuRow(
          '个人主页',
          'user',
          () => _navigate('me'),
          color: const Color(0xff7796b7),
        ),
        _menuRow(
          '设置',
          'settings',
          () => _navigate('settings'),
          color: const Color(0xff8ca1b1),
        ),
      ],
    ],
  );

  String get _selfName =>
      _store.userCard['称呼']?.isNotEmpty == true ? _store.userCard['称呼']! : '我';
  Widget _me() => ColoredBox(
    color: _wx ? const Color(0xffededed) : Colors.white,
    child: ListView(
      key: const PageStorageKey('native-me'),
      padding: EdgeInsets.zero,
      children: [
        Material(
          color: Colors.white,
          child: InkWell(
            onTap: () => _navigate('profile'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 34, 24, 30),
              child: Row(
                children: [
                  NativeSocialPortrait(
                    mode: _mode,
                    user: true,
                    store: _store,
                    size: 64,
                    large: true,
                    borderRadius: 7,
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selfName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          '${_wx ? '微信号' : 'QQ 号'}：${_store.userCard['社交账号'] ?? 'skivu_island'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xff888888),
                            height: 1.9,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xffdddddd)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _wx
                                ? '＋ 状态'
                                : '☻ ${_store.userCard['个人状态'] ?? '记录生活中'}',
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: Color(0xff666666),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const NativeSocialIcon(
                    'qr',
                    size: 18,
                    color: Color(0xff999999),
                  ),
                  if (_wx) ...[
                    const SizedBox(width: 13),
                    const NativeSocialIcon(
                      'right',
                      size: 16,
                      color: Color(0xffb2b2b2),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_wx) ...[
          _menuRow(
            '服务',
            'wallet',
            () => _navigate('services'),
            color: const Color(0xff07c160),
          ),
          const SizedBox(height: 8),
          _menuRow(
            '收藏',
            'box',
            () => _navigate('favorites'),
            color: const Color(0xfffa9d3b),
            divider: true,
          ),
          _menuRow(
            '朋友圈',
            'image',
            () => _navigate('moments'),
            color: const Color(0xff2782d7),
            divider: true,
          ),
          _menuRow(
            '卡包',
            'wallet',
            () => _navigate('cards'),
            color: const Color(0xff2782d7),
            divider: true,
          ),
          _menuRow(
            '表情',
            'smile',
            () => widget.go('/stickers'),
            color: const Color(0xfffa9d3b),
          ),
        ] else ...[
          _menuRow(
            '个人状态',
            'smile',
            () => _navigate('status'),
            note: _store.userCard['个人状态'] ?? '记录生活中',
            color: const Color(0xff68a394),
            divider: true,
          ),
          _menuRow(
            '我的空间',
            'image',
            () => _navigate('moments'),
            color: const Color(0xff6d9dbd),
          ),
          const SizedBox(height: 8),
          _menuRow(
            '收藏',
            'star',
            () => _navigate('favorites'),
            color: const Color(0xffdcad63),
            divider: true,
          ),
          _menuRow(
            '相册',
            'image',
            () => _navigate('albums'),
            color: const Color(0xff699bc8),
            divider: true,
          ),
          _menuRow(
            '表情',
            'smile',
            () => widget.go('/stickers'),
            color: const Color(0xffd6aa65),
            divider: true,
          ),
          _menuRow(
            '文件',
            'folder',
            () => _navigate('files'),
            color: const Color(0xff7c9fba),
          ),
        ],
        const SizedBox(height: 8),
        _menuRow(
          '设置',
          'settings',
          () => _navigate('settings'),
          color: _wx ? const Color(0xff2782d7) : const Color(0xff78909f),
        ),
        if (!_wx) ...[
          const SizedBox(height: 9),
          _menuRow(
            'QQ 钱包',
            'wallet',
            () => _navigate('wallet'),
            color: const Color(0xff5470a1),
          ),
        ],
      ],
    ),
  );

  Widget _home({bool profile = false}) {
    final qqInbox = !_wx && _tab == 0 && !profile;
    final me = _wx && _tab == 3;
    final count = _tab == 0
        ? _unread()
        : (!_wx && _tab == 1 ? _unread(channel: true) : 0);
    final countText = count > 99 ? '99+' : '$count';
    final headerColor = me
        ? Colors.white
        : qqInbox
        ? const Color(0xffe6e9f5)
        : _wx
        ? const Color(0xffededed)
        : const Color(0xffefeff1);
    final tabs = _tabs;
    return LayoutBuilder(
      builder: (context, box) {
        _viewHeight = box.maxHeight;
        return Column(
          children: [
            ColoredBox(
              color: headerColor,
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: qqInbox
                      ? 62
                      : _wx
                      ? 52
                      : 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (qqInbox)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 17),
                          child: Row(
                            children: [
                              InkWell(
                                onTap: widget.openNavigation,
                                child: SizedBox(
                                  width: 42,
                                  height: 48,
                                  child: Center(
                                    child: NativeSocialPortrait(
                                      mode: _mode,
                                      user: true,
                                      store: _store,
                                      size: 39,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: InkWell(
                                  onTap: widget.openNavigation,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _selfName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      Text(
                                        '消息${count > 0 ? '($countText)' : ''}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xff797d89),
                                          height: 1.55,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 36,
                                height: 44,
                                child: IconButton(
                                  tooltip: '添加对话',
                                  padding: EdgeInsets.zero,
                                  onPressed: _addMenu,
                                  icon: const NativeSocialIcon(
                                    'plus',
                                    size: 25,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        if (!me)
                          Align(
                            alignment: _wx
                                ? Alignment.center
                                : Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: _wx ? 70 : 20,
                              ),
                              child: Text(
                                profile
                                    ? '个人主页'
                                    : '${tabs[_tab]}${count > 0 ? '($countText)' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xff191919),
                                ),
                              ),
                            ),
                          ),
                        if (profile || _tab == 0 || _tab == (_wx ? 1 : 2))
                          Positioned(
                            right: 12,
                            child: Row(
                              children: [
                                if (_wx && _tab == 0)
                                  SizedBox(
                                    width: 36,
                                    height: 44,
                                    child: IconButton(
                                      tooltip: '搜索',
                                      padding: EdgeInsets.zero,
                                      onPressed: () {
                                        _query = '';
                                        _searchChatOnly = false;
                                        _navigate('search');
                                      },
                                      icon: const NativeSocialIcon(
                                        'search',
                                        size: 25,
                                      ),
                                    ),
                                  ),
                                SizedBox(
                                  width: 36,
                                  height: 44,
                                  child: IconButton(
                                    tooltip: profile
                                        ? '个人设置'
                                        : _tab == 0
                                        ? '添加好友或群聊'
                                        : '添加朋友',
                                    padding: EdgeInsets.zero,
                                    onPressed: profile
                                        ? () => _navigate('settings')
                                        : _tab == 0
                                        ? _addMenu
                                        : _friends,
                                    icon: NativeSocialIcon(
                                      profile
                                          ? 'settings'
                                          : _wx
                                          ? 'plus-circle'
                                          : 'plus',
                                      size: 25,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: profile
                  ? _me()
                  : PageView.builder(
                      key: const ValueKey('native-social-pager'),
                      controller: _pages,
                      physics: _edgeGesture
                          ? const NeverScrollableScrollPhysics()
                          : const ClampingScrollPhysics(),
                      itemCount: 4,
                      onPageChanged: (v) {
                        setState(() => _tab = v);
                        uiPlugins.tab = v;
                      },
                      itemBuilder: (context, i) => AnimatedBuilder(
                        animation: _pages,
                        child: _KeepSocialPage(
                          child: _wx
                              ? switch (i) {
                                  0 => _inbox(false),
                                  1 => _contacts(),
                                  2 => _discover(),
                                  _ => _me(),
                                }
                              : switch (i) {
                                  0 => _inbox(false),
                                  1 => _channels(),
                                  2 => _contacts(),
                                  _ => _discover(),
                                },
                        ),
                        builder: (context, child) {
                          final position =
                              _pages.hasClients &&
                                  _pages.position.haveDimensions
                              ? _pages.page ?? _tab.toDouble()
                              : _tab.toDouble();
                          final amount = (position - i).abs().clamp(0.0, 1.0);
                          return Transform.scale(
                            scale: 1 - .025 * amount,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12 * amount),
                              child: child,
                            ),
                          );
                        },
                      ),
                    ),
            ),
            Container(
              key: const ValueKey('native-social-tabs'),
              height: 57,
              padding: const EdgeInsets.fromLTRB(7, 4, 7, 0),
              decoration: BoxDecoration(
                color: _wx ? const Color(0xfff7f7f7) : Colors.white,
                border: const Border(
                  top: BorderSide(color: Color(0xffdedede), width: .5),
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < 4; i++)
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          if (profile) {
                            _tab = i;
                            uiPlugins.tab = i;
                            _navigate('home');
                            return;
                          }
                          if (_pages.hasClients)
                            _pages.animateToPage(
                              i,
                              duration: Duration(
                                milliseconds: appearance.flag('reduceMotion')
                                    ? 0
                                    : 260,
                              ),
                              curve: Curves.easeOutCubic,
                            );
                        },
                        child: Semantics(
                          selected: !profile && _tab == i,
                          label: tabs[i],
                          button: true,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  NativeSocialIcon(
                                    (_wx
                                        ? [
                                            'chat',
                                            'address-book',
                                            'compass',
                                            'user',
                                          ]
                                        : [
                                            'chat',
                                            'hash',
                                            'user',
                                            'qq-zone',
                                          ])[i],
                                    size: 26,
                                    filled: !profile && _tab == i,
                                    strokeWidth: 1.55,
                                    color: !profile && _tab == i
                                        ? (_wx
                                              ? const Color(0xff07c160)
                                              : const Color(0xff0099ff))
                                        : const Color(0xff181818),
                                  ),
                                  if (i == 0 || !_wx && i == 1)
                                    Positioned(
                                      right: -5,
                                      top: -2,
                                      child: _badge(
                                        i == 1
                                            ? _unread(channel: true)
                                            : _unread(),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                tabs[i],
                                style: TextStyle(
                                  fontSize: 11,
                                  color: !profile && _tab == i
                                      ? (_wx
                                            ? const Color(0xff07c160)
                                            : const Color(0xff0099ff))
                                      : const Color(0xff181818),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _friends() async {
    _contactQuery = '';
    _navigate('friends');
  }

  Widget _friendsPage() => _frame(
    '添加朋友',
    Column(
      children: [
        _NativeSocialRootSearch(
          wechat: _wx,
          placeholder: '角色名称',
          onChanged: (v) => setState(() => _contactQuery = v),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final p in _store.personas.where(
                (p) =>
                    p.name.toLowerCase().contains(_contactQuery.toLowerCase()),
              ))
                _contactRow(p),
              _menuRow('创建新角色', 'plus', () => widget.go('/characters')),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _frame(
    String title,
    Widget body, {
    List<Widget> actions = const [],
    VoidCallback? onBack,
  }) => Material(
    color: _wx ? const Color(0xffededed) : const Color(0xfff4f5f7),
    child: Column(
      children: [
        Container(
          color: _wx ? const Color(0xffededed) : Colors.white,
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: Color(0xff191919),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  top: 5,
                  child: Semantics(
                    button: true,
                    label: '返回',
                    child: InkWell(
                      onTap: onBack ?? _back,
                      child: const SizedBox(
                        width: 34,
                        height: 44,
                        child: Center(
                          child: NativeSocialIcon('chevron-left', size: 24),
                        ),
                      ),
                    ),
                  ),
                ),
                if (actions.isNotEmpty)
                  Positioned(
                    right: 10,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: body),
      ],
    ),
  );

  Future<T?> _showRootPage<T>(
    String title,
    Widget Function(BuildContext) body,
  ) => Navigator.of(context).push<T>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (route) => Scaffold(
        body: SafeArea(
          top: false,
          child: _frame(title, body(route), onBack: () => Navigator.pop(route)),
        ),
      ),
    ),
  );

  Widget _contact() {
    final role = _role(_contactId) ?? _role(_chat.personaId);
    if (role == null) return _frame('联系人', _empty('角色已不存在。'));
    return NativeSocialContactDetails(
      mode: _mode,
      store: _store,
      role: role,
      onBack: _back,
      onRename: () => _renameRole(role),
      onEditRole: () {
        _store.persona = _store.personas.indexOf(role);
        widget.go('/characters/edit');
      },
      onPrivacy: () => _navigate('privacy', contact: role.id),
      onMoments: () => _navigate('moments'),
      onMoreInfo: () => _navigate('bio', contact: role.id),
      onChat: () => _chooseChat(role),
      onCall: () => _navigate('call-preview', contact: role.id),
    );
  }

  Future<void> _renameRole(Persona role) async {
    final text = TextEditingController(text: role.name);
    final saved = await _showRootPage<bool>(
      '备注和标签',
      (route) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        children: [
          const Text('备注名', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            controller: text,
            maxLength: 80,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '与 Skivu 共用角色名称。',
            style: TextStyle(fontSize: 12, color: Color(0xff888888)),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 45,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              onPressed: () => Navigator.pop(route, true),
              child: const Text(
                '保存',
                style: TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
    if (saved == true && mounted) {
      final error = _binding.mutate({
        'protocol': 1,
        'command': 'renameRole',
        'roleId': role.id,
        'name': text.text,
      }, mode: _mode);
      if (error != null) _notice(error);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    text.dispose();
  }

  Widget _groups() => NativeSocialGroupList(
    mode: _mode,
    store: _store,
    onBack: _back,
    onCreate: () => _groupConfig(),
    onOpen: _openChat,
  );

  Widget _info() => NativeSocialChatInfo(
    mode: _mode,
    store: _store,
    chat: _chat,
    onBack: _back,
    onRole: (p) => _navigate('contact', contact: p.id),
    onUser: () => _navigate('profile'),
    onAddMembers: () => _groupConfig(
      _chat.groupMembers.isEmpty ? null : _chat,
      false,
      [if (_chat.personaId != null) _chat.personaId!],
    ),
    onSearch: () {
      _query = '';
      _searchChatOnly = true;
      _navigate('search');
    },
    onToggle: _toggleChatOption,
    onBackground: () => _appearance(1),
    onBubbles: () => _appearance(2),
    onClear: _clearChat,
    onReport: () => _navigate('report'),
  );

  Future<void> _toggleChatOption(String key, bool value) async {
    final chatId = _chat.id;
    if (key == 'replyReminder' && value) {
      final yes = await _showRootPage<bool>(
        '提醒',
        (route) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          children: [
            const Text(
              '开启后，当前对话收到完整回复时会在应用内显示提示。',
              style: TextStyle(
                fontSize: 14,
                height: 1.8,
                color: Color(0xff888888),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 45,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => Navigator.pop(route, true),
                child: const Text(
                  '开启提醒',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    if (!mounted || _chat.id != chatId) return;
    final error = _binding.mutate({
      'protocol': 1,
      'command': 'chatOptions',
      'chatId': chatId,
      'key': key,
      'value': value,
    }, mode: _mode);
    if (error != null) _notice(error);
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _clearChat() async {
    final chat = _chat;
    if (!await _confirm('清空聊天记录？', '只清空当前这段对话，保留角色与对话入口。')) return;
    if (!mounted || _chat.id != chat.id) return;
    final saved = _store.clearChatMessages(chat.id);
    if (saved != null && mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已清空当前聊天记录'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _store.restoreClearedMessages(saved),
          ),
        ),
      );
  }

  Future<void> _appearance(int section) async {
    final legacy = _chat.chatBackground;
    if (section == 1 &&
        legacy != null &&
        wallpaper.data == null &&
        appearance.text('videoAsset').isEmpty) {
      try {
        await wallpaper.importImage(base64Decode(legacy.split(',').last));
        appearance.set('backgroundEnabled', true);
        await appearance.save();
      } catch (_) {
        /* Keep the original archive available. */
      }
      if (!mounted) return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .9,
        child: Column(
          children: [
            ListTile(
              title: Text(section == 1 ? '自定义聊天背景' : '聊天气泡与字体'),
              trailing: IconButton(
                tooltip: '完成',
                onPressed: () => Navigator.pop(sheet),
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: AppearanceSettings(initialSection: section),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _search() {
    final query = _query.trim().toLowerCase();
    final chats = SocialChatBinding(
      _store,
    ).inbox.where((c) => !_searchChatOnly || c.id == _chat.id);
    return _frame(
      '搜索',
      Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const ValueKey('native-social-search'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索角色、对话或消息',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (!_searchChatOnly)
                  for (final p in _store.personas.where(
                    (p) =>
                        query.isNotEmpty &&
                        p.name.toLowerCase().contains(query),
                  ))
                    ListTile(
                      leading: NativeSocialPortrait(mode: _mode, persona: p),
                      title: Text(p.name),
                      subtitle: const Text('角色'),
                      onTap: () => _navigate('contact', contact: p.id),
                    ),
                for (final c in chats) ...[
                  if (query.isNotEmpty && c.title.toLowerCase().contains(query))
                    ListTile(
                      title: Text(c.title),
                      subtitle: const Text('对话'),
                      onTap: () => _openChat(c),
                    ),
                  for (final m
                      in c.messages
                          .where(
                            (m) =>
                                query.isNotEmpty &&
                                m.text.toLowerCase().contains(query),
                          )
                          .take(100))
                    ListTile(
                      title: Text(
                        m.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(c.title),
                      onTap: () => _openChat(c, locate: m),
                    ),
                ],
                if (query.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Text('输入关键词搜索本机记录', textAlign: TextAlign.center),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addMenu() async {
    if (!_wx) {
      await _showRootPage<void>(
        '添加',
        (route) => ListView(
          padding: EdgeInsets.zero,
          children: [
            _menuRow('新建对话', 'chat', () {
              Navigator.pop(route);
              unawaited(_newChatPage());
            }),
            _menuRow('角色管理', 'users', () {
              Navigator.pop(route);
              widget.go('/characters');
            }),
            _menuRow('我的资料与头像', 'user', () {
              Navigator.pop(route);
              unawaited(editUserCard(context));
            }),
            _menuRow('回到原版', 'cloud', () {
              Navigator.pop(route);
              unawaited(uiPlugins.apply(ChatUiMode.classic));
            }),
          ],
        ),
      );
      return;
    }
    final box = context.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final origin = box.localToGlobal(
      Offset(box.size.width - 184, MediaQuery.paddingOf(context).top + 49),
    );
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 174, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints.tightFor(width: 174),
      color: const Color(0xff4b4b4b),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      menuPadding: EdgeInsets.zero,
      items: [
        for (final x in [
          ('group', '发起群聊', 'users'),
          ('friends', '添加朋友', 'user'),
          ('scan', '扫一扫', 'qr'),
          ('cashier', '收付款', 'wallet'),
        ])
          PopupMenuItem(
            value: x.$1,
            height: 51,
            padding: const EdgeInsets.symmetric(horizontal: 17),
            child: Row(
              children: [
                NativeSocialIcon(x.$3, size: 22, color: Colors.white),
                const SizedBox(width: 14),
                Text(
                  x.$2,
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'group') {
      await _groupConfig();
      return;
    }
    if (action == 'friends') {
      await _friends();
      return;
    }
    _navigate(action);
  }

  Future<void> _newChatPage() async {
    await _showRootPage<void>(
      '选择角色',
      (route) => ListView(
        padding: const EdgeInsets.only(bottom: 25),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '选择角色新建独立对话',
              style: const TextStyle(fontSize: 13, color: Color(0xff888888)),
            ),
          ),
          for (final p in _store.personas)
            Material(
              color: Colors.white,
              child: InkWell(
                onTap: () {
                  Navigator.pop(route);
                  _store.newChat(personaId: p.id);
                  _openChat(_chat);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      NativeSocialPortrait(mode: _mode, persona: p, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          p.name,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      const NativeSocialIcon(
                        'right',
                        size: 16,
                        color: Color(0xffb2b2b2),
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

  Future<void> _groupConfig([
    Conversation? existing,
    bool channel = false,
    List<String> initialMembers = const [],
  ]) async {
    final currentId = _chat.id;
    final result = await showNativeSocialGroupForm(
      context,
      mode: _mode,
      store: _store,
      existingChat: existing,
      initialMembers: initialMembers,
      channel: channel,
    );
    if (result == null || !mounted) return;
    if (_chat.id != currentId) {
      _notice('当前对话已切换，请重试。');
      return;
    }
    final error = _binding.mutate({
      'protocol': 1,
      'command': existing == null ? 'createGroup' : 'groupConfig',
      'chatId': currentId,
      'members': result.members,
      'title': result.title,
      'rule': result.rule,
      'maxReplies': result.maxReplies,
      'kind': result.kind,
    }, mode: _mode);
    if (error != null)
      _notice(error);
    else
      _openChat(_chat);
  }

  Future<void> _chatMenu(Conversation chat) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(chat.title)),
          for (final item in [
            ('pin', chat.pinned ? '取消置顶' : '置顶'),
            ('rename', '重命名'),
            ('delete', '删除对话'),
          ])
            ListTile(
              title: Text(item.$2),
              onTap: () => Navigator.pop(c, item.$1),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'pin') _store.toggleChatPin(chat.id);
    if (action == 'delete' &&
        await _confirm('删除对话？', '将删除“${chat.title}”及其记录，角色卡和其他对话保留。') &&
        mounted) {
      _store.deleteChat(chat.id);
      if (_page != 'home') _navigate('home');
    }
    if (action == 'rename') {
      final controller = TextEditingController(text: chat.title);
      final title = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('重命名对话'),
          content: TextField(controller: controller, maxLength: 80),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (title != null && mounted) _store.renameChat(chat.id, title);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_page) {
      'home' => _home(),
      'chat' => const SizedBox.shrink(),
      'chat-info' => _info(),
      'contact' => _contact(),
      'friends' => _friendsPage(),
      'me' => _home(profile: true),
      'bio' => _frame(
        '更多信息',
        _empty(
          (_role(_contactId) ?? _role(_chat.personaId))?.subtitle ??
              '角色资料由 Skivu 统一管理',
        ),
      ),
      'report' => _frame('投诉', _empty('本地界面预览，不会向微信或 QQ 提交投诉。')),
      'groups' => _groups(),
      'search' => _search(),
      _ => NativeSocialExtras(
        key: ValueKey(_page),
        page: _page,
        mode: _mode,
        navigate: _navigate,
        go: widget.go,
        onBack: _back,
        onRole: (id) => _navigate('contact', contact: id),
        previewRole: _role(_contactId),
      ),
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _page != 'home' && widget.backBlocked?.call() != true)
          _back();
      },
      child: PluginEdgeControls(
        reduceMotion: appearance.flag('reduceMotion'),
        onExit: () async {
          await _store.saveChats();
          return uiPlugins.apply(ChatUiMode.classic);
        },
        child: Listener(
          onPointerDown: (e) {
            final box = context.findRenderObject();
            if (box is RenderBox &&
                PluginEdgeControls.edgeRegion(
                  box.size,
                ).contains(e.localPosition))
              setState(() => _edgeGesture = true);
          },
          onPointerUp: (_) {
            if (_edgeGesture) setState(() => _edgeGesture = false);
          },
          onPointerCancel: (_) {
            if (_edgeGesture) setState(() => _edgeGesture = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _page == 'chat'
                ? (_) => _backDrag = 0
                : null,
            onHorizontalDragUpdate: _page == 'chat'
                ? (e) {
                    if (!_edgeGesture) _backDrag += e.primaryDelta ?? 0;
                  }
                : null,
            onHorizontalDragEnd: _page == 'chat'
                ? (_) {
                    if (!_edgeGesture && _backDrag > 64) _back();
                    _backDrag = 0;
                  }
                : null,
            child: Material(
              color: _page == 'chat'
                  ? Colors.transparent
                  : const Color(0xffededed),
              child: Stack(
                children: [
                  if (_keepChat)
                    Offstage(
                      offstage: _page != 'chat',
                      child: NativeSocialChat(
                        key: ValueKey('native-chat-${_chat.id}'),
                        mode: _mode,
                        store: _store,
                        go: widget.go,
                        navigate: _navigate,
                        onRole: (id) => _navigate('contact', contact: id),
                        active: _page == 'chat',
                        onBack: _back,
                        onInfo: () => _navigate('chat-info'),
                        locateMessage: _locate,
                      ),
                    ),
                  if (_page != 'chat') Positioned.fill(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialMenuSeparator extends CustomPainter {
  const _SocialMenuSeparator();
  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
    Offset(57, size.height - .25),
    Offset(size.width, size.height - .25),
    Paint()
      ..color = const Color(0xffeeeeee)
      ..strokeWidth = .5,
  );
  @override
  bool shouldRepaint(_SocialMenuSeparator oldDelegate) => false;
}

class _KeepSocialPage extends StatefulWidget {
  const _KeepSocialPage({required this.child});
  final Widget child;
  @override
  State<_KeepSocialPage> createState() => _KeepSocialPageState();
}

class _NativeSocialRootSearch extends StatefulWidget {
  const _NativeSocialRootSearch({
    super.key,
    required this.wechat,
    required this.placeholder,
    required this.onChanged,
  });
  final bool wechat;
  final String placeholder;
  final ValueChanged<String> onChanged;
  @override
  State<_NativeSocialRootSearch> createState() =>
      _NativeSocialRootSearchState();
}

class _NativeSocialRootSearchState extends State<_NativeSocialRootSearch> {
  final _focus = FocusNode();
  final _text = TextEditingController();
  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.wechat ? const Color(0xffededed) : const Color(0xffe6e9f5),
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        widget.wechat ? 16 : 12,
        widget.wechat ? 7 : 6,
        widget.wechat ? 16 : 12,
        12,
      ),
      child: LayoutBuilder(
        builder: (context, box) => SizedBox(
          height: 34,
          child: Stack(
            children: [
              TextField(
                textAlignVertical: TextAlignVertical.center,
                controller: _text,
                focusNode: _focus,
                onChanged: (v) {
                  setState(() {});
                  widget.onChanged(v);
                },
                textAlign: _focus.hasFocus || _text.text.isNotEmpty
                    ? TextAlign.start
                    : TextAlign.center,
                style: TextStyle(
                  fontSize: widget.wechat ? 16 : 15,
                  height: 1,
                  color: const Color(0xff191919),
                ),
                decoration: InputDecoration(
                  constraints: const BoxConstraints.tightFor(height: 34),
                  hintText: widget.placeholder,
                  hintStyle: const TextStyle(color: Color(0xffa8a8a8)),
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 35,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(widget.wechat ? 5 : 8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              Positioned(
                left: _focus.hasFocus || _text.text.isNotEmpty
                    ? 11
                    : box.maxWidth / 2 - 36,
                top: 8,
                child: const IgnorePointer(
                  child: NativeSocialIcon(
                    'search',
                    size: 17,
                    color: Color(0xffb2b2b2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _KeepSocialPageState extends State<_KeepSocialPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
