import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'appearance.dart';
import 'appearance_settings.dart';
import 'character_avatar.dart';
import 'chat_controls.dart';
import 'legacy_social_migration.dart';
import 'native_social_chat.dart';
import 'native_social_extras.dart';
import 'plugin_edge_controls.dart';
import 'social_activity.dart';
import 'social_settings.dart';
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
  bool _searchChatOnly = false, _edgeGesture = false;
  double _backDrag = 0;
  bool _keepChat = uiPlugins.conversationVisible;
  String? _replyChat;
  bool get _wx => _mode == ChatUiMode.wechat;
  Color get _accent => _wx ? const Color(0xff07a960) : const Color(0xff1497e8);
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
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .65,
        child: Column(
          children: [
            ListTile(
              title: Text(role.name),
              subtitle: const Text('角色卡共用，每段对话独立保存'),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final c
                      in _store
                          .conversationsFor(role.id)
                          .where((c) => c.groupMembers.isEmpty))
                    ListTile(
                      title: Text(c.title),
                      subtitle: Text(
                        _preview(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: c.id == _chat.id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        Navigator.pop(sheet);
                        _openChat(c);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('新建独立对话'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _store.newChat(personaId: role.id);
                      _openChat(_chat);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
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
              : CharacterAvatar(
                  persona: _role(c.personaId)!,
                  size: 48,
                  square: _wx,
                ))
        : Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xffdddfe3),
              borderRadius: BorderRadius.circular(_wx ? 7 : 24),
            ),
            child: GridView.count(
              crossAxisCount: 2,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              children: roles
                  .map(
                    (p) => Padding(
                      padding: const EdgeInsets.all(1),
                      child: CharacterAvatar(
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
              _wx ||
              (channel ? c.groupKind == 'channel' : c.groupKind != 'channel'),
        )
        .toList();
    final activity = {for (final c in chats) c.id: _latestActivity(c)};
    chats.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return (activity[b.id]!.at ?? DateTime(1970)).compareTo(
        activity[a.id]!.at ?? DateTime(1970),
      );
    });
    return Material(
      color: Colors.white,
      child: ListView.builder(
        key: PageStorageKey('native-inbox-${_mode.name}-$channel'),
        padding: EdgeInsets.zero,
        itemCount: chats.isEmpty ? 1 : chats.length,
        itemBuilder: (context, index) {
          if (chats.isEmpty)
            return Padding(
              padding: const EdgeInsets.all(40),
              child: Text(
                channel ? '还没有频道，点击右上角创建。' : '还没有对话，点击右上角选择角色新建。',
                textAlign: TextAlign.center,
              ),
            );
          final c = chats[index], role = _role(c.personaId);
          final at = activity[c.id]!.at;
          return Material(
            color: c.pinned ? const Color(0xffededed) : Colors.white,
            child: InkWell(
              onTap: () => _openChat(c),
              onLongPress: () => _chatMenu(c),
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    _face(c),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 74),
                        padding: const EdgeInsets.fromLTRB(0, 12, 14, 12),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Color(0xffe5e5e5),
                              width: .5,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.groupMembers.isNotEmpty
                                        ? c.title
                                        : role?.name ?? c.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 17),
                                  ),
                                ),
                                if (at != null)
                                  Text(
                                    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _preview(c),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                if (c.muted)
                                  const Icon(
                                    Icons.notifications_off_outlined,
                                    color: Colors.grey,
                                    size: 15,
                                  ),
                              ],
                            ),
                            if (c.groupMembers.isEmpty && c.titleEdited)
                              Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(
    String title,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
    Color? color,
  }) => Material(
    color: Colors.white,
    child: ListTile(
      leading: Icon(icon, color: color ?? _accent),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: action,
    ),
  );
  Widget _contacts() => ListView(
    key: const PageStorageKey('native-contacts'),
    padding: EdgeInsets.zero,
    children: [
      _row(
        '角色管理',
        Icons.person_add_outlined,
        () => widget.go('/characters'),
        subtitle: '管理本机角色卡',
      ),
      _row('群聊', Icons.groups_outlined, () => _navigate('groups')),
      if (!_wx) _row('通话记录', Icons.call_outlined, () => _navigate('calls')),
      const Padding(
        padding: EdgeInsets.all(14),
        child: Text('我的角色', style: TextStyle(color: Colors.grey, fontSize: 12)),
      ),
      for (final p in _store.personas)
        Material(
          color: Colors.white,
          child: ListTile(
            leading: CharacterAvatar(persona: p, size: 42, square: _wx),
            title: Text(p.name),
            subtitle: p.subtitle.isEmpty
                ? null
                : Text(
                    p.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _navigate('contact', contact: p.id),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          '${_store.personas.length} 位角色',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ),
    ],
  );
  Widget _discover() => ListView(
    key: const PageStorageKey('native-discover'),
    padding: const EdgeInsets.only(top: 10),
    children: [
      _row(
        _wx ? '朋友圈' : '好友动态',
        Icons.explore_outlined,
        () => _navigate('moments'),
        color: const Color(0xff2782d7),
      ),
      if (!_wx) ...[
        const SizedBox(height: 10),
        _row('我的空间', Icons.account_circle_outlined, () => _navigate('me')),
        _row('相册', Icons.photo_library_outlined, () => _navigate('albums')),
        _row('收藏', Icons.star_border, () => _navigate('favorites')),
        _row('文件', Icons.folder_outlined, () => _navigate('files')),
        _row('设置', Icons.settings_outlined, () => _navigate('settings')),
      ],
    ],
  );
  Widget _me() => ListView(
    key: const PageStorageKey('native-me'),
    padding: EdgeInsets.zero,
    children: [
      Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: UserAvatar(size: 60, square: _wx),
            title: Text(
              _store.userCard['称呼']?.isNotEmpty == true
                  ? _store.userCard['称呼']!
                  : '我',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(_store.userCard['社交账号'] ?? 'Skivu 本机资料'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _navigate('profile'),
          ),
        ),
      ),
      const SizedBox(height: 10),
      _row('服务', Icons.wallet_outlined, () => _navigate('services')),
      const SizedBox(height: 10),
      _row('收藏', Icons.bookmark_border, () => _navigate('favorites')),
      _row('朋友圈', Icons.photo_outlined, () => _navigate('moments')),
      _row('相册', Icons.photo_library_outlined, () => _navigate('albums')),
      _row('表情', Icons.emoji_emotions_outlined, () => widget.go('/stickers')),
      const SizedBox(height: 10),
      _row('设置', Icons.settings_outlined, () => _navigate('settings')),
      _row(
        '返回 Skivu 原版',
        Icons.exit_to_app,
        () => uiPlugins.apply(ChatUiMode.classic),
      ),
    ],
  );
  Widget _home() => Column(
    children: [
      Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              if (!_wx && _tab == 0)
                IconButton(
                  tooltip: '个人资料',
                  onPressed: () => _navigate('me'),
                  icon: const Icon(Icons.account_circle_outlined),
                ),
              Expanded(
                child: Text(
                  '${_tabs[_tab]}${(_tab == 0
                              ? _unread()
                              : !_wx && _tab == 1
                              ? _unread(channel: true)
                              : 0) > 0 ? ' (${_tab == 0 ? _unread() : _unread(channel: true)})' : ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                tooltip: '搜索',
                onPressed: () {
                  _query = '';
                  _searchChatOnly = false;
                  _navigate('search');
                },
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: '添加好友或群聊',
                onPressed: _addMenu,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: PageView.builder(
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
                      1 => _inbox(true),
                      2 => _contacts(),
                      _ => _discover(),
                    },
            ),
            builder: (context, child) {
              final position =
                  _pages.hasClients && _pages.position.haveDimensions
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
      BottomNavigationBar(
        key: const ValueKey('native-social-tabs'),
        type: BottomNavigationBarType.fixed,
        currentIndex: _tab,
        selectedItemColor: _accent,
        unselectedItemColor: const Color(0xff252525),
        backgroundColor: const Color(0xfffafafa),
        selectedFontSize: 12,
        unselectedFontSize: 12,
        onTap: (i) {
          if (_pages.hasClients)
            _pages.animateToPage(
              i,
              duration: Duration(
                milliseconds: appearance.flag('reduceMotion') ? 0 : 260,
              ),
              curve: Curves.easeOutCubic,
            );
        },
        items: [
          for (var i = 0; i < 4; i++)
            BottomNavigationBarItem(
              label: _tabs[i],
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    (_wx
                        ? [
                            Icons.chat_bubble_outline,
                            Icons.contacts_outlined,
                            Icons.explore_outlined,
                            Icons.person_outline,
                          ]
                        : [
                            Icons.chat_bubble_outline,
                            Icons.tag,
                            Icons.contacts_outlined,
                            Icons.explore_outlined,
                          ])[i],
                    size: 25,
                  ),
                  if (i == 0 || !_wx && i == 1)
                    Positioned(
                      top: -6,
                      right: -9,
                      child: _badge(
                        i == 1 ? _unread(channel: true) : _unread(),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ],
  );
  Widget _frame(String title, Widget body, {List<Widget> actions = const []}) =>
      Material(
        color: const Color(0xffededed),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: SizedBox(
                height: 52,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: _back,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
  Widget _contact() {
    final p = _role(_contactId);
    if (p == null) return _frame('角色资料', const Center(child: Text('角色已不存在')));
    return _frame(
      '角色资料',
      ListView(
        padding: EdgeInsets.zero,
        children: [
          const SizedBox(height: 12),
          Material(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  CharacterAvatar(persona: p, size: 70, square: _wx),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          p.subtitle.isNotEmpty ? p.subtitle : '本机角色卡',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          _row('编辑角色卡', Icons.edit_outlined, () {
            _store.persona = _store.personas.indexOf(p);
            widget.go('/characters/edit');
          }),
          _row(
            '角色二维码',
            Icons.qr_code,
            () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(p.name),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NativeSocialQr(data: 'skivu://role/${p.id}'),
                    const SizedBox(height: 12),
                    const Text(
                      '仅用于本机 Skivu 角色识别',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () => _chooseChat(p),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('发消息'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => _voiceFor(p),
              icon: const Icon(Icons.call_outlined),
              label: const Text('语音通话'),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.videocam_off_outlined),
            title: Text('视频通话'),
            subtitle: Text('开发中'),
            enabled: false,
          ),
        ],
      ),
    );
  }

  Future<void> _voiceFor(Persona p) async {
    final chats = _store
        .conversationsFor(p.id)
        .where((c) => c.groupMembers.isEmpty)
        .toList();
    if (chats.isNotEmpty)
      SocialChatBinding(_store).activate(chats.first.id);
    else
      _store.newChat(personaId: p.id);
    uiPlugins.showConversation();
    widget.go('/call');
  }

  Widget _groups() => _frame(
    '群聊',
    ListView(
      padding: EdgeInsets.zero,
      children: [
        _row('发起群聊', Icons.group_add_outlined, () => _groupConfig()),
        for (final c in SocialChatBinding(
          _store,
        ).inbox.where((c) => c.groupMembers.length >= 2))
          ListTile(
            leading: _face(c),
            title: Text(c.title),
            subtitle: Text(
              '${c.groupMembers.length} 位角色 · ${c.groupKind == 'channel' ? '频道' : '群聊'}',
            ),
            onTap: () => _openChat(c),
          ),
      ],
    ),
  );
  Widget _info() => _frame(
    '聊天信息',
    ListView(
      padding: EdgeInsets.zero,
      children: [
        if (_chat.groupMembers.length >= 2) ...[
          Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 18,
              runSpacing: 14,
              children: [
                for (final p
                    in _chat.groupMembers.map(_role).whereType<Persona>())
                  InkWell(
                    onTap: () => _navigate('contact', contact: p.id),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CharacterAvatar(persona: p, size: 44, square: _wx),
                        const SizedBox(height: 5),
                        Text(p.name, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _row('群成员与发言规则', Icons.groups_outlined, () => _groupConfig(_chat)),
        ] else if (_role(_chat.personaId) != null)
          ListTile(
            leading: CharacterAvatar(
              persona: _role(_chat.personaId)!,
              size: 52,
              square: _wx,
            ),
            title: Text(_role(_chat.personaId)!.name),
            subtitle: Text(_chat.title),
            onTap: () => _navigate('contact', contact: _chat.personaId),
          ),
        _row('查找聊天记录', Icons.search, () {
          _query = '';
          _searchChatOnly = true;
          _navigate('search');
        }),
        for (final option in [
          ('pinned', '置顶聊天', _chat.pinned),
          ('muted', '消息免打扰', _chat.muted),
          ('confirmBeforeReply', '分条输入，确认后统一回复', _chat.confirmBeforeReply),
          ('replyReminder', '完整回复时应用内提示', _chat.replyReminder),
        ])
          Material(
            color: Colors.white,
            child: SwitchListTile(
              title: Text(option.$2),
              value: option.$3,
              activeThumbColor: _accent,
              onChanged: (v) async {
                final chatId = _chat.id;
                if (option.$1 == 'replyReminder' &&
                    v &&
                    !await _confirm(
                      '开启回复提醒？',
                      '仅在App内收到完整回复时提示，不申请系统通知权限，静音聊天不提示。',
                    ))
                  return;
                if (!mounted || _chat.id != chatId) return;
                final error = _binding.mutate({
                  'protocol': 1,
                  'command': 'chatOptions',
                  'chatId': chatId,
                  'key': option.$1,
                  'value': v,
                }, mode: _mode);
                if (error != null) _notice(error);
              },
            ),
          ),
        const SizedBox(height: 10),
        _row('自定义聊天背景', Icons.wallpaper_outlined, () => _appearance(1)),
        _row('聊天气泡与字体', Icons.format_paint_outlined, () => _appearance(2)),
        _row('模型设置', Icons.tune, () => showChatModelPicker(context)),
        _row(
          '社交与群聊设置',
          Icons.groups_outlined,
          () => widget.go('/settings/social'),
        ),
        const SizedBox(height: 10),
        _row(
          '清空聊天记录',
          Icons.delete_sweep_outlined,
          _clearChat,
          color: Colors.red,
        ),
        _row(
          '返回 Skivu 原版',
          Icons.exit_to_app,
          () => uiPlugins.apply(ChatUiMode.classic),
        ),
      ],
    ),
  );
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
                      leading: CharacterAvatar(persona: p),
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
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in [
            ('chat', '新建对话', Icons.chat_bubble_outline),
            ('group', '发起群聊', Icons.group_add_outlined),
            if (!_wx) ('channel', '创建频道', Icons.tag),
            ('roles', '角色管理', Icons.person_add_outlined),
            ('scan', '扫一扫', Icons.qr_code_scanner),
            ('cashier', '收付款', Icons.wallet_outlined),
          ])
            ListTile(
              leading: Icon(item.$3),
              title: Text(item.$2),
              onTap: () => Navigator.pop(c, item.$1),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'roles') {
      widget.go('/characters');
      return;
    }
    if (action == 'group' || action == 'channel') {
      await _groupConfig(null, action == 'channel');
      return;
    }
    if (action == 'chat') {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheet) => SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .6,
          child: ListView(
            children: [
              const ListTile(title: Text('选择角色')),
              for (final p in _store.personas)
                ListTile(
                  leading: CharacterAvatar(persona: p),
                  title: Text(p.name),
                  onTap: () {
                    Navigator.pop(sheet);
                    _store.newChat(personaId: p.id);
                    _openChat(_chat);
                  },
                ),
            ],
          ),
        ),
      );
      return;
    }
    _navigate(action);
  }

  Future<void> _groupConfig([
    Conversation? existing,
    bool channel = false,
  ]) async {
    final input = TextEditingController(text: existing?.title ?? '');
    final members = {
      ...(existing?.groupMembers ?? socialSettings.value.groupMembers)
          .where((id) => _role(id) != null)
          .take(8),
    };
    var rule = existing?.groupRule ?? socialSettings.value.groupRule.name,
        limit =
            existing?.groupMaxReplies ?? socialSettings.value.groupMaxReplies;
    final approved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, change) => AlertDialog(
          title: Text(
            existing == null ? (channel ? '创建频道' : '发起群聊') : '群成员与发言规则',
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: input,
                    maxLength: 60,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  const Text('选择2—8位现有角色，按规则依次回复'),
                  for (final p in _store.personas)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(p.name),
                      value: members.contains(p.id),
                      onChanged: (v) => change(() {
                        if (v == true && members.length < 8)
                          members.add(p.id);
                        else if (v != true)
                          members.remove(p.id);
                      }),
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: rule,
                    decoration: const InputDecoration(labelText: '发言规则'),
                    items:
                        [
                              ('automatic', '自动（优先@，否则轮流）'),
                              ('roundRobin', '轮流发言'),
                              ('mentions', '仅@的角色'),
                              ('manual', '手动'),
                            ]
                            .map(
                              (r) => DropdownMenuItem(
                                value: r.$1,
                                child: Text(r.$2),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => change(() => rule = v!),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: limit,
                    decoration: const InputDecoration(labelText: '每轮最多回复人数'),
                    items: [
                      for (var i = 1; i <= 6; i++)
                        DropdownMenuItem(value: i, child: Text('$i')),
                    ],
                    onChanged: (v) => change(() => limit = v!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: members.length >= 2 && members.length <= 8
                  ? () => Navigator.pop(c, true)
                  : null,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (approved == true && mounted) {
      if (existing != null && _chat.id != existing.id) {
        _notice('当前对话已切换，请重试。');
      } else {
        final error = _binding.mutate({
          'protocol': 1,
          'command': existing == null ? 'createGroup' : 'groupConfig',
          'chatId': _chat.id,
          'members': members.toList(),
          'title': input.text,
          'rule': rule,
          'maxReplies': limit,
          'kind': existing?.groupKind ?? (channel ? 'channel' : 'group'),
        }, mode: _mode);
        if (error != null)
          _notice(error);
        else
          _openChat(_chat);
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
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

  Widget _files() {
    final events = [
      for (final c in _store.conversations)
        for (final e in c.interactions)
          if (e['kind'] == 'file' && !c.hiddenInteractions.contains(e['id']))
            (c, e),
    ];
    return _frame(
      '文件',
      ListView(
        children: [
          if (events.isEmpty) const ListTile(title: Text('还没有本机文件消息')),
          for (final e in events)
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text('${(e.$2['payload'] as Map?)?['name'] ?? '文件'}'),
              subtitle: Text(e.$1.title),
              onTap: () => _openChat(e.$1),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_page) {
      'home' => _home(),
      'chat' => const SizedBox.shrink(),
      'chat-info' => _info(),
      'contact' => _contact(),
      'groups' => _groups(),
      'search' => _search(),
      'files' => _files(),
      _ => NativeSocialExtras(
        key: ValueKey(_page),
        page: _page,
        mode: _mode,
        navigate: _navigate,
        go: widget.go,
        onBack: _back,
        onRole: (id) => _navigate('contact', contact: id),
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

class _KeepSocialPage extends StatefulWidget {
  const _KeepSocialPage({required this.child});
  final Widget child;
  @override
  State<_KeepSocialPage> createState() => _KeepSocialPageState();
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
