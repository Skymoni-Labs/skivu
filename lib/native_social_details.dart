import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'native_social_portrait.dart';
import 'native_social_icons.dart';
import 'social_settings.dart';
import 'state.dart';
import 'ui_plugins.dart';

const _ink = Color(0xff191919);
const _grey = Color(0xffededed);
Color _accent(ChatUiMode mode) =>
    mode == ChatUiMode.qq ? const Color(0xff009dff) : const Color(0xff07c160);

/// Shared original full-screen overlay chrome. It consumes the top safe inset
/// once, and relies on the enclosing Scaffold for keyboard resizing.
class _DetailsFrame extends StatelessWidget {
  const _DetailsFrame({
    required this.mode,
    required this.title,
    required this.onBack,
    required this.child,
    this.overlay = false,
    this.centerTitle = true,
    this.background,
    this.headerColor,
    this.titleSize = 17,
  });
  final ChatUiMode mode;
  final String title;
  final VoidCallback onBack;
  final Widget child;
  final bool overlay, centerTitle;
  final Color? background, headerColor;
  final double titleSize;
  @override
  Widget build(BuildContext context) => Material(
    color:
        background ?? (mode == ChatUiMode.qq ? const Color(0xfff4f5f7) : _grey),
    child: DefaultTextStyle(
      style: const TextStyle(fontSize: 16, color: _ink, height: 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('native-social-details-header'),
            color:
                headerColor ??
                (mode == ChatUiMode.qq ? const Color(0xffefeff1) : _grey),
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: SizedBox(
              width: double.infinity,
              height: overlay
                  ? 54
                  : mode == ChatUiMode.qq
                  ? 56
                  : 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: centerTitle
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: centerTitle ? 48 : 52,
                      ),
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: centerTitle
                            ? TextAlign.center
                            : TextAlign.left,
                        style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w500,
                        ),
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
                        onTap: onBack,
                        child: const SizedBox(
                          width: 34,
                          height: 44,
                          child: Center(
                            child: NativeSocialIcon(
                              'interaction-back',
                              size: 23,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(
    this.label,
    this.onTap, {
    this.divider = true,
    this.fontSize = 16,
  });
  final String label;
  final VoidCallback onTap;
  final bool divider;
  final double fontSize;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 55),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: divider
              ? const Border(bottom: BorderSide(color: Color(0xfff0f0f0)))
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: fontSize)),
            ),
            const SizedBox(width: 12),
            const NativeSocialIcon('right', size: 16, color: Color(0xffb9b9b9)),
          ],
        ),
      ),
    ),
  );
}

Widget _group(List<Widget> children, {bool qq = false}) => Container(
  margin: EdgeInsets.only(bottom: qq ? 13 : 10),
  padding: EdgeInsets.symmetric(horizontal: qq ? 15 : 16),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(qq ? 12 : 0),
  ),
  clipBehavior: Clip.antiAlias,
  child: Column(mainAxisSize: MainAxisSize.min, children: children),
);

class NativeSocialContactDetails extends StatelessWidget {
  const NativeSocialContactDetails({
    super.key,
    required this.mode,
    required this.store,
    required this.role,
    required this.onBack,
    required this.onRename,
    required this.onEditRole,
    required this.onPrivacy,
    required this.onMoments,
    required this.onMoreInfo,
    required this.onChat,
    required this.onCall,
  });
  final ChatUiMode mode;
  final DemoStore store;
  final Persona role;
  final VoidCallback onBack,
      onRename,
      onEditRole,
      onPrivacy,
      onMoments,
      onMoreInfo,
      onChat,
      onCall;
  @override
  Widget build(BuildContext context) => _DetailsFrame(
    mode: mode,
    title: role.name,
    centerTitle: mode != ChatUiMode.qq,
    background: mode == ChatUiMode.qq ? Colors.white : _grey,
    onBack: onBack,
    child: ListView(
      key: PageStorageKey('social-contact-details-${role.id}'),
      padding: const EdgeInsets.only(bottom: 25),
      children: [
        Container(
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 9),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 25),
          child: Row(
            children: [
              NativeSocialPortrait(
                mode: mode,
                persona: role,
                size: 64,
                large: true,
                borderRadius: mode == ChatUiMode.qq ? null : 5,
              ),
              const SizedBox(width: 17),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.name,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '角色卡：${role.name}\n${role.subtitle.isEmpty ? '角色资料由 Skivu 统一管理' : role.subtitle}',
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.9,
                        color: Color(0xff889ba8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _contactGroup([
          _ContactMenuRow('备注和标签', 'user', onRename),
          _ContactMenuRow('编辑角色卡', 'sliders', onEditRole),
          _ContactMenuRow('朋友权限', 'user', onPrivacy, divider: false),
        ]),
        _contactGroup([
          _ContactMenuRow(
            mode == ChatUiMode.qq ? 'QQ空间' : '朋友圈',
            'image',
            onMoments,
          ),
          _ContactMenuRow('更多信息', 'more', onMoreInfo, divider: false),
        ]),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(18, 15, 18, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mode == ChatUiMode.wechat)
                Align(
                  child: SizedBox(
                    width: 184,
                    child: _PrimaryButton('发消息', onChat, color: _accent(mode)),
                  ),
                )
              else
                _PrimaryButton('发消息', onChat, color: const Color(0xff0099ff)),
              const SizedBox(height: 12),
              InkWell(
                onTap: onCall,
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Text(
                    '音视频通话',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xff657b8b)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _contactGroup(List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    color: Colors.white,
    child: Column(children: children),
  );
}

class _ContactMenuRow extends StatelessWidget {
  const _ContactMenuRow(
    this.label,
    this.icon,
    this.onTap, {
    this.divider = true,
  });
  final String label, icon;
  final VoidCallback onTap;
  final bool divider;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 55),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
              child: Row(
                children: [
                  NativeSocialIcon(
                    icon,
                    size: 22,
                    color: const Color(0xff586e91),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 16)),
                  ),
                  const NativeSocialIcon(
                    'right',
                    size: 13,
                    color: Color(0xffb2b2b2),
                  ),
                ],
              ),
            ),
            if (divider)
              const Positioned(
                left: 57,
                right: 0,
                bottom: 0,
                child: Divider(
                  height: .5,
                  thickness: .5,
                  color: Color(0xffeeeeee),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// All actions are callbacks. In particular this widget never toggles or saves
/// the selected conversation itself after an asynchronous confirmation.
class NativeSocialChatInfo extends StatelessWidget {
  const NativeSocialChatInfo({
    super.key,
    required this.mode,
    required this.store,
    required this.chat,
    required this.onBack,
    required this.onRole,
    required this.onUser,
    required this.onAddMembers,
    required this.onSearch,
    required this.onToggle,
    required this.onBackground,
    required this.onBubbles,
    required this.onClear,
    required this.onReport,
  });
  final ChatUiMode mode;
  final DemoStore store;
  final Conversation chat;
  final VoidCallback onBack,
      onUser,
      onAddMembers,
      onSearch,
      onBackground,
      onBubbles,
      onClear,
      onReport;
  final ValueChanged<Persona> onRole;
  final void Function(String key, bool value) onToggle;
  Persona? _role(String? id) =>
      store.personas.where((p) => p.id == id).firstOrNull;
  bool get _qq => mode == ChatUiMode.qq;
  bool get _isGroup => chat.groupMembers.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final owner = _role(chat.personaId);
    Widget members({required bool add}) => _MemberGrid(
      mode: mode,
      store: store,
      roles: _isGroup
          ? chat.groupMembers.map(_role).whereType<Persona>().toList()
          : [if (owner != null) owner],
      includeSelf: _isGroup,
      onUser: onUser,
      onRole: onRole,
      onAdd: add ? onAddMembers : null,
    );
    Widget toggle(
      String key,
      String label,
      bool value, {
      bool divider = true,
    }) => _ToggleRow(
      label: label,
      value: value,
      mode: mode,
      onChanged: (next) => onToggle(key, next),
      toggleKey: ValueKey('native-social-toggle-$key'),
      divider: divider,
    );
    Widget row(String label, VoidCallback action, {bool divider = true}) =>
        _DetailRow(label, action, divider: divider, fontSize: _qq ? 15 : 16);
    return _DetailsFrame(
      mode: mode,
      title: _qq ? '聊天设置' : '聊天信息',
      headerColor: _qq ? Colors.white : _grey,
      titleSize: _qq ? 18 : 17,
      onBack: onBack,
      child: ListView(
        key: PageStorageKey('social-chat-info-${chat.id}'),
        padding: EdgeInsets.fromLTRB(
          _qq ? 14 : 0,
          _qq ? 14 : 0,
          _qq ? 14 : 0,
          25,
        ),
        children: [
          if (_qq)
            _group([
              InkWell(
                onTap: _isGroup
                    ? onAddMembers
                    : owner == null
                    ? null
                    : () => onRole(owner),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 80),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xfff5f5f6)),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (owner != null)
                        NativeSocialPortrait(
                          mode: mode,
                          persona: owner,
                          size: 48,
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _isGroup ? chat.title : owner?.name ?? '角色已不存在',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const NativeSocialIcon(
                        'right',
                        size: 16,
                        color: Color(0xffbbbbbb),
                      ),
                    ],
                  ),
                ),
              ),
              if (_isGroup) members(add: false),
              row(
                _isGroup
                    ? (chat.groupKind == 'channel' ? '频道成员与设置' : '群成员与设置')
                    : '发起群聊',
                onAddMembers,
                divider: false,
              ),
            ], qq: true)
          else
            Container(
              color: Colors.white,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(22, 23, 22, 20),
              child: members(add: true),
            ),
          _group([row('查找聊天记录', onSearch, divider: false)], qq: _qq),
          _group(
            _qq
                ? [
                    toggle('pinned', '设为置顶', chat.pinned),
                    toggle('replyReminder', '特别关心', chat.replyReminder),
                    toggle('muted', '消息免打扰', chat.muted),
                    toggle(
                      'confirmBeforeReply',
                      '确认后再回复',
                      chat.confirmBeforeReply,
                      divider: false,
                    ),
                  ]
                : [
                    toggle('muted', '消息免打扰', chat.muted),
                    toggle(
                      'confirmBeforeReply',
                      '确认后再回复',
                      chat.confirmBeforeReply,
                    ),
                    toggle('pinned', '置顶聊天', chat.pinned),
                    toggle(
                      'replyReminder',
                      '提醒',
                      chat.replyReminder,
                      divider: false,
                    ),
                  ],
            qq: _qq,
          ),
          _group([
            row('自定义背景', onBackground),
            row('聊天气泡', onBubbles, divider: false),
          ], qq: _qq),
          _group([row('清空聊天记录', onClear, divider: false)], qq: _qq),
          if (!_qq) _group([row('投诉', onReport, divider: false)]),
        ],
      ),
    );
  }
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({
    required this.mode,
    required this.store,
    required this.roles,
    required this.includeSelf,
    required this.onUser,
    required this.onRole,
    this.onAdd,
  });
  final ChatUiMode mode;
  final DemoStore store;
  final List<Persona> roles;
  final bool includeSelf;
  final VoidCallback onUser;
  final ValueChanged<Persona> onRole;
  final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final qq = mode == ChatUiMode.qq;
      final columns = math.max(
        1,
        math.min(qq ? 4 : 5, ((bounds.maxWidth + 12) / 62).floor()),
      );
      final width = (bounds.maxWidth - (columns - 1) * 12) / columns;
      Widget member(Widget avatar, String name, VoidCallback action) =>
          SizedBox(
            width: width,
            child: InkWell(
              onTap: action,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatar,
                  const SizedBox(height: 8),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff777777),
                    ),
                  ),
                ],
              ),
            ),
          );
      // The old native.css selector overrides the nominal 50px WX portrait.
      // Its actual member portrait is 44px; the add box remains 50px.
      final size = qq ? 38.0 : 44.0;
      return Padding(
        padding: EdgeInsets.symmetric(vertical: qq ? 17 : 0),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (includeSelf)
              member(
                NativeSocialPortrait(
                  mode: mode,
                  user: true,
                  store: store,
                  size: size,
                ),
                store.userCard['称呼'] ?? '我',
                onUser,
              ),
            for (final role in roles)
              member(
                NativeSocialPortrait(mode: mode, persona: role, size: size),
                role.name,
                () => onRole(role),
              ),
            if (onAdd != null)
              SizedBox(
                width: width,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Semantics(
                    label: '添加聊天成员',
                    button: true,
                    child: InkWell(
                      onTap: onAdd,
                      child: CustomPaint(
                        painter: _DashedBorder(),
                        child: const SizedBox.square(
                          dimension: 50,
                          child: Center(
                            child: NativeSocialIcon(
                              'plus',
                              size: 30,
                              color: Color(0xffaaaaaa),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)),
      );
    final paint = Paint()
      ..color = const Color(0xffc8c8c8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (double at = 0; at < metric.length; at += 7) {
        canvas.drawPath(
          metric.extractPath(at, math.min(at + 4, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) => false;
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.mode,
    required this.onChanged,
    required this.toggleKey,
    this.divider = true,
  });
  final String label;
  final bool value;
  final ChatUiMode mode;
  final ValueChanged<bool> onChanged;
  final Key toggleKey;
  final bool divider;
  @override
  Widget build(BuildContext context) {
    final qq = mode == ChatUiMode.qq;
    final trackWidth = qq ? 43.0 : 50.0, trackHeight = qq ? 26.0 : 29.0;
    return Container(
      constraints: const BoxConstraints(minHeight: 55),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: divider
            ? const Border(bottom: BorderSide(color: Color(0xfff0f0f0)))
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: qq ? 15 : 16)),
          ),
          const SizedBox(width: 12),
          Semantics(
            toggled: value,
            label: label,
            child: GestureDetector(
              key: toggleKey,
              onTap: () => onChanged(!value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: trackWidth,
                height: trackHeight,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: value
                      ? _accent(mode)
                      : qq
                      ? const Color(0xffe9eaee)
                      : const Color(0xffe5e5e5),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: value
                        ? _accent(mode)
                        : qq
                        ? const Color(0xffe9eaee)
                        : const Color(0xffdddddd),
                  ),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 150),
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: qq ? 20 : 24,
                    height: qq ? 20 : 24,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NativeSocialGroupList extends StatelessWidget {
  const NativeSocialGroupList({
    super.key,
    required this.mode,
    required this.store,
    required this.onBack,
    required this.onCreate,
    required this.onOpen,
  });
  final ChatUiMode mode;
  final DemoStore store;
  final VoidCallback onBack, onCreate;
  final ValueChanged<Conversation> onOpen;
  @override
  Widget build(BuildContext context) {
    final chats = SocialChatBinding(store).inbox
        .where((c) => c.groupMembers.isNotEmpty && c.groupKind != 'channel')
        .toList();
    return _DetailsFrame(
      mode: mode,
      title: '群聊',
      centerTitle: mode != ChatUiMode.qq,
      background: mode == ChatUiMode.qq ? Colors.white : _grey,
      onBack: onBack,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          for (final chat in chats)
            Material(
              color: Colors.white,
              child: InkWell(
                onTap: () => onOpen(chat),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 70),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xfff2f2f2)),
                    ),
                  ),
                  child: Row(
                    children: [
                      const NativeSocialIcon('users', size: 22),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(chat.title),
                            Text(
                              '${chat.groupMembers.length + 1} 位成员',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xff999999),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const NativeSocialIcon(
                        'right',
                        size: 16,
                        color: Color(0xffbbbbbb),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Material(
            color: Colors.white,
            child: InkWell(
              onTap: onCreate,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 17, horizontal: 20),
                child: Row(
                  children: [
                    NativeSocialIcon('plus', size: 22),
                    SizedBox(width: 16),
                    Text('发起群聊'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NativeSocialGroupValue {
  NativeSocialGroupValue({
    required this.title,
    required List<String> members,
    required this.rule,
    required this.maxReplies,
    required this.kind,
  }) : members = List.unmodifiable(members);
  final String title, rule, kind;
  final List<String> members;
  final int maxReplies;
}

Future<NativeSocialGroupValue?> showNativeSocialGroupForm(
  BuildContext context, {
  required ChatUiMode mode,
  required DemoStore store,
  Conversation? existingChat,
  List<String> initialMembers = const [],
  bool channel = false,
}) => Navigator.of(context).push<NativeSocialGroupValue>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _GroupForm(
      mode: mode,
      store: store,
      existing: existingChat,
      initialMembers: initialMembers,
      channel: channel,
    ),
  ),
);

class _GroupForm extends StatefulWidget {
  const _GroupForm({
    required this.mode,
    required this.store,
    required this.existing,
    required this.initialMembers,
    required this.channel,
  });
  final ChatUiMode mode;
  final DemoStore store;
  final Conversation? existing;
  final List<String> initialMembers;
  final bool channel;
  @override
  State<_GroupForm> createState() => _GroupFormState();
}

class _GroupFormState extends State<_GroupForm> {
  static const rules = <String, String>{
    'manual': '首位成员回复，可用 @ 指定',
    'mentions': '仅回应 @ 的成员',
    'roundRobin': '按成员顺序轮流',
    'automatic': '优先回应 @ 提及，否则轮流',
  };
  late final TextEditingController _title;
  late final Set<String> _members;
  late String _rule, _kind;
  late int _limit;
  String? _error;
  @override
  void initState() {
    super.initState();
    final defaults = socialSettings.value, existing = widget.existing;
    _kind = existing?.groupKind ?? (widget.channel ? 'channel' : 'group');
    _title = TextEditingController(
      text: existing?.title ?? (_kind == 'channel' ? '角色频道' : '角色群聊'),
    );
    final roles = widget.store.personas.map((p) => p.id).toSet();
    _members =
        (existing?.groupMembers ??
                [...widget.initialMembers, ...defaults.groupMembers])
            .where(roles.contains)
            .toSet()
            .take(8)
            .toSet();
    _rule = existing?.groupRule ?? defaults.groupRule.name;
    if (!rules.containsKey(_rule)) _rule = 'manual';
    _limit = (existing?.groupMaxReplies ?? defaults.groupMaxReplies).clamp(
      1,
      6,
    );
    widget.store.addListener(_storeChanged);
  }

  void _storeChanged() {
    if (!mounted) return;
    final valid = widget.store.personas.map((p) => p.id).toSet();
    setState(() => _members.removeWhere((id) => !valid.contains(id)));
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final valid = widget.store.personas.map((p) => p.id).toSet();
    if (_title.text.trim().isEmpty ||
        _title.text.length > 60 ||
        _members.length < 2 ||
        _members.length > 8 ||
        !_members.every(valid.contains)) {
      setState(() => _error = '请填写群名称并选择 2—8 位现有角色。');
      return;
    }
    Navigator.pop(
      context,
      NativeSocialGroupValue(
        title: _title.text.trim(),
        // The original FormData followed checkbox/role display order. Preserve
        // that order because it also controls round-robin reply order.
        members: widget.store.personas
            .where((role) => _members.contains(role.id))
            .map((role) => role.id)
            .toList(),
        rule: _rule,
        maxReplies: _limit,
        kind: _kind,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null, channel = _kind == 'channel';
    final name = channel ? '频道' : '群聊';
    return Scaffold(
      backgroundColor: widget.mode == ChatUiMode.qq
          ? const Color(0xfff4f5f7)
          : _grey,
      body: SafeArea(
        top: false,
        child: _DetailsFrame(
          mode: widget.mode,
          overlay: true,
          headerColor: widget.mode == ChatUiMode.qq ? Colors.white : _grey,
          title: editing
              ? '${name}成员与设置'
              : channel
              ? '创建频道'
              : '发起群聊',
          onBack: () => Navigator.pop(context),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label(channel ? '频道名称' : '群名称'),
                TextField(
                  key: const ValueKey('native-social-group-title'),
                  controller: _title,
                  maxLength: 60,
                  style: const TextStyle(fontSize: 16),
                  decoration: _inputDecoration(),
                ),
                const SizedBox(height: 8),
                Text(
                  '选择 2—8 位角色；$name记录独立，角色卡与原版共用。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff999999),
                  ),
                ),
                const SizedBox(height: 14),
                for (final role in widget.store.personas) _selection(role),
                const SizedBox(height: 19),
                _label('回复规则'),
                DropdownButtonFormField<String>(
                  key: const ValueKey('native-social-group-rule'),
                  initialValue: _rule,
                  isExpanded: true,
                  decoration: _inputDecoration(),
                  items: rules.entries
                      .map(
                        (entry) => DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                            entry.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _rule = value);
                  },
                ),
                const SizedBox(height: 19),
                _label('每轮最多回复'),
                DropdownButtonFormField<int>(
                  key: const ValueKey('native-social-group-limit'),
                  initialValue: _limit,
                  isExpanded: true,
                  decoration: _inputDecoration(),
                  items: [
                    for (var n = 1; n <= 6; n++)
                      DropdownMenuItem(value: n, child: Text('$n 位成员')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _limit = value);
                  },
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    '每位回复成员使用一次模型请求，仅发送本群上下文。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: Color(0xff999999),
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xffd4443a),
                      ),
                    ),
                  ),
                _PrimaryButton(
                  editing
                      ? '保存'
                      : channel
                      ? '创建频道'
                      : '创建群聊',
                  _submit,
                  color: _accent(widget.mode),
                  buttonKey: const ValueKey('native-social-group-save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _selection(Persona role) {
    final selected = _members.contains(role.id);
    return Material(
      color: Colors.white,
      child: InkWell(
        key: ValueKey('native-social-group-member-${role.id}'),
        onTap: () => setState(() {
          _error = null;
          if (selected) {
            _members.remove(role.id);
          } else if (_members.length < 8) {
            _members.add(role.id);
          } else {
            _error = '最多选择 8 位角色。';
          }
        }),
        child: Semantics(
          checked: selected,
          label: role.name,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xfff2f2f2))),
            ),
            child: Row(
              children: [
                NativeSocialPortrait(
                  mode: widget.mode,
                  persona: role,
                  size: 42,
                  borderRadius: 5,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(role.name, style: const TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? _accent(widget.mode) : Colors.white,
                    border: Border.all(
                      color: selected
                          ? _accent(widget.mode)
                          : const Color(0xffcccccc),
                      width: 1.3,
                    ),
                  ),
                  child: selected
                      ? const NativeSocialIcon(
                          'check',
                          size: 17,
                          color: Colors.white,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(text, style: const TextStyle(fontSize: 14)),
  );
  InputDecoration _inputDecoration() => InputDecoration(
    filled: true,
    fillColor: Colors.white,
    isDense: true,
    contentPadding: const EdgeInsets.all(12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(5),
      borderSide: BorderSide.none,
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton(
    this.label,
    this.onTap, {
    required this.color,
    this.buttonKey,
  });
  final String label;
  final VoidCallback onTap;
  final Color color;
  final Key? buttonKey;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    borderRadius: BorderRadius.circular(5),
    child: InkWell(
      key: buttonKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 45),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      ),
    ),
  );
}
