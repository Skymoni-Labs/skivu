import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'state.dart';
import 'widgets.dart';
import 'glass.dart';
import 'chat_bubble_surface.dart';
import 'chat_status_bar.dart';
import 'appearance.dart';
import 'model_settings.dart';
import 'relay_account.dart';
import 'relay_account_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.openWorkspace,
    required this.openCall,
    this.openModels,
  });
  final VoidCallback openWorkspace, openCall;
  final VoidCallback? openModels;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final keys = <Message, GlobalKey>{};
  // Each non-overlapping role shares one backdrop input at its own blur value.
  final _userBackdrop = BackdropKey(), _replyBackdrop = BackdropKey();
  Timer? navTimer;
  bool showNav = false, radial = false, follow = true;
  int selected = 0, oldCount = 0;
  late Conversation _conversation;
  @override
  void initState() {
    super.initState();
    _conversation = demo.conversations[demo.conversation];
    input.text = _conversation.draft;
    input.addListener(() => demo.saveDraft(_conversation, input.text));
    focus.addListener(() {
      if (focus.hasFocus) hideNavigation();
    });
    demo.addListener(update);
  }

  void update() {
    if (!mounted) return;
    final current = demo.conversations[demo.conversation];
    if (!identical(current, _conversation)) {
      _conversation = current;
      input.text = current.draft;
      keys.clear();
      follow = true;
      showNav = false;
    }
    if (demo.messages.length != oldCount || (demo.streaming && follow)) {
      oldCount = demo.messages.length;
      if (follow)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients)
            scroll.animateTo(
              scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
            );
        });
    }
    setState(() {});
  }

  @override
  void dispose() {
    demo.removeListener(update);
    input.dispose();
    focus.dispose();
    scroll.dispose();
    navTimer?.cancel();
    super.dispose();
  }

  void hideNavigation() {
    navTimer?.cancel();
    if (mounted)
      setState(() {
        showNav = false;
        radial = false;
      });
  }

  void revealNavigation() {
    if (focus.hasFocus || demo.messages.isEmpty) return;
    navTimer?.cancel();
    setState(() => showNav = true);
    navTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted && !radial) hideNavigation();
    });
  }

  void locate(int index) {
    if (demo.messages.isEmpty) return;
    final key = keys[demo.messages[index.clamp(0, demo.messages.length - 1)]];
    if (key?.currentContext != null)
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        alignment: .13,
      );
    setState(() {
      radial = false;
      showNav = false;
      follow = false;
    });
  }

  void send() {
    final value = input.text;
    if (value.trim().isEmpty || demo.streaming) return;
    hideNavigation();
    follow = true;
    if (!demo.send(value)) {
      if (demo.lastError != null) toast(context, demo.lastError!);
      if (demo.activeConnection == null) openModels();
      return;
    }
    input.clear();
    focus.unfocus();
    demo.saveChats();
  }

  void openModels() {
    if (demo.useAccount) {
      Navigator.of(context).pushReplacementNamed('/settings/account');
      return;
    }
    if (demo.useBeta) {
      Navigator.of(context).pushReplacementNamed('/settings/beta');
      return;
    }
    if (widget.openModels != null) {
      widget.openModels!();
    } else {
      Navigator.of(context).pushNamed('/settings/models');
    }
  }

  void picker(bool role) => showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * .8),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label(role ? '对话角色' : '选择模型', size: 21, weight: FontWeight.w600),
            const SizedBox(height: 6),
            label(
              role ? '角色设定用于之后发送的消息。' : '选择已配置的模型连接。',
              size: 12,
              color: muted,
            ),
            const SizedBox(height: 18),
            if (role)
              for (int i = 0; i < demo.personas.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: demo.personas[i].color.withValues(
                      alpha: .12,
                    ),
                    child: Icon(
                      demo.personas[i].icon,
                      color: demo.personas[i].color,
                      size: 21,
                    ),
                  ),
                  title: Text(demo.personas[i].name),
                  subtitle: Text(
                    demo.personas[i].subtitle,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: i == demo.persona
                      ? Icon(Icons.check_circle, color: green, size: 20)
                      : null,
                  onTap: () {
                    demo.persona = i;
                    demo.changed();
                    demo.saveChats();
                    Navigator.pop(c);
                  },
                )
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.account_circle_outlined, color: green),
                title: const Text('中转站账号'),
                subtitle: Text(
                  relayAccount.signedIn
                      ? relayAccount.activeModel ?? '同步可用模型'
                      : '登录即可同步模型和额度',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: demo.useAccount
                    ? Icon(Icons.check_circle, color: green, size: 20)
                    : null,
                onTap: demo.streaming
                    ? null
                    : () async {
                        Navigator.pop(c);
                        if (relayAccount.canChat)
                          await pickRelayModel(context);
                        else
                          Navigator.of(
                            context,
                          ).pushReplacementNamed('/settings/account');
                      },
              ),
              for (final profile in modelSettings.connections)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.hub_outlined, color: green),
                  title: Text(profile.name),
                  subtitle: Text(
                    profile.model,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: profile.id == modelSettings.activeId
                      ? Icon(Icons.check_circle, color: green, size: 20)
                      : null,
                  onTap: demo.streaming
                      ? null
                      : () async {
                          try {
                            await modelSettings.select(profile.id);
                            demo.useBeta = false;
                            demo.useAccount = false;
                            demo.changed();
                            demo.saveChats();
                            if (c.mounted) Navigator.pop(c);
                          } catch (_) {
                            if (c.mounted) toast(c, '无法保存选择，请重试');
                          }
                        },
                ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(c);
                  Navigator.of(
                    context,
                  ).pushReplacementNamed('/settings/models');
                },
                icon: const Icon(Icons.add),
                label: const Text('管理模型连接'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.science_outlined, color: green),
                title: const Text('Skymoni 内测'),
                subtitle: const Text(
                  '配对设备，使用独立内测额度',
                  style: TextStyle(fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(c);
                  Navigator.of(context).pushReplacementNamed('/settings/beta');
                },
              ),
            ],
          ],
        ),
      ),
    ),
  );
  void messageNavigator() {
    hideNavigation();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 650),
      builder: (c) {
        String query = '';
        bool saved = false;
        return StatefulBuilder(
          builder: (c, change) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .66,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      label('消息定位', size: 22, weight: FontWeight.w600),
                      const Spacer(),
                      FilterChip(
                        label: const Text('仅收藏'),
                        selected: saved,
                        onSelected: (v) => change(() => saved = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索这段对话',
                    ),
                    onChanged: (v) => change(() => query = v),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      children: [
                        for (int i = 0; i < demo.messages.length; i++)
                          if (demo.messages[i].text.contains(query) &&
                              (!saved || demo.messages[i].bookmarked))
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 6,
                              ),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: mist,
                                child: label('${i + 1}', size: 11, color: ink),
                              ),
                              title: Text(
                                demo.messages[i].text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              subtitle: label(
                                demo.messages[i].user ? '你' : demo.role.name,
                                size: 10,
                                color: muted,
                              ),
                              trailing: demo.messages[i].bookmarked
                                  ? Icon(Icons.bookmark, size: 17, color: green)
                                  : const Icon(
                                      Icons.north_west,
                                      size: 16,
                                      color: muted,
                                    ),
                              onTap: () {
                                Navigator.pop(c);
                                locate(i);
                              },
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void attachments() => showModalBottomSheet(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label('添加到这段对话', size: 22, weight: FontWeight.w600),
          const SizedBox(height: 8),
          label('本阶段只添加示例附件，不读取你的文件。', size: 12, color: muted),
          const SizedBox(height: 20),
          SettingRow(
            '灵感笔记.md',
            '演示文件 · 1.2 KB',
            icon: Icons.description_outlined,
            onTap: () {
              demo.attached = true;
              demo.changed();
              Navigator.pop(c);
            },
          ),
          SettingRow(
            '从工作区选择',
            '浏览示例文件与预览',
            icon: Icons.folder_outlined,
            onTap: () {
              Navigator.pop(c);
              widget.openWorkspace();
            },
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Column(
        children: [
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if ((n is ScrollUpdateNotification && n.dragDetails != null) ||
                    (n is UserScrollNotification &&
                        n.direction != ScrollDirection.idle)) {
                  revealNavigation();
                  follow = false;
                }
                return false;
              },
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(
                  appearance.flag('wideChat') ? 8 : 14,
                  20,
                  appearance.flag('wideChat') ? 8 : 14,
                  24,
                ),
                children: [
                  if (demo.messages.isEmpty)
                    emptyState()
                  else ...[
                    Center(
                      child: label(
                        '与 ${demo.role.name} 的对话',
                        size: 10,
                        color: muted,
                      ),
                    ),
                    const SizedBox(height: 25),
                    for (int i = 0; i < demo.messages.length; i++)
                      message(demo.messages[i], i),
                    if (demo.streaming && appearance.flag('showStatus'))
                      Padding(
                        padding: const EdgeInsets.only(left: 44),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 9,
                              height: 9,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                            const SizedBox(width: 8),
                            label('正在回复…', size: 10, color: muted),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          composer(),
          if (demo.storageError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                demo.storageError!,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      if (showNav && demo.messages.isNotEmpty)
        Positioned(
          right: radial ? 21 : 95,
          bottom: radial ? 146 : 220,
          child: MouseRegion(
            onExit: (_) {
              if (radial) hideNavigation();
            },
            child: SizedBox(
              width: radial ? 190 : 42,
              height: radial ? 190 : 42,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (radial) ...[
                    Container(
                      width: 184,
                      height: 184,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: .96),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: ink.withValues(alpha: .12),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                      child: CustomPaint(
                        painter: NavigationTicks(
                          demo.messages.length,
                          selected,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 24,
                      child: label(
                        '${selected + 1} / ${demo.messages.length}',
                        size: 11,
                        color: green,
                      ),
                    ),
                    Positioned(
                      bottom: 22,
                      child: label('松开定位', size: 9, color: muted),
                    ),
                  ],
                  Semantics(
                    label: '消息导航：点击定位，长按环形导航',
                    button: true,
                    child: GestureDetector(
                      onTap: messageNavigator,
                      onLongPressStart: (_) {
                        navTimer?.cancel();
                        setState(() {
                          radial = true;
                          selected = 0;
                        });
                      },
                      onLongPressMoveUpdate: (d) {
                        final vector = d.offsetFromOrigin;
                        final angle =
                            (math.atan2(vector.dy, vector.dx) + math.pi * 2) %
                            (math.pi * 2);
                        setState(
                          () => selected =
                              (angle / (math.pi * 2) * demo.messages.length)
                                  .floor()
                                  .clamp(0, demo.messages.length - 1),
                        );
                      },
                      onLongPressEnd: (_) => locate(selected),
                      onLongPressCancel: hideNavigation,
                      child: Tooltip(
                        triggerMode: TooltipTriggerMode.manual,
                        message: '点击定位 · 长按环形导航',
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: green.withValues(alpha: .64),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.arrow_back,
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget composer() => Padding(
    padding: EdgeInsets.fromLTRB(
      appearance.flag('floatingInput') ? 10 : 0,
      6,
      appearance.flag('floatingInput') ? 10 : 0,
      appearance.flag('floatingInput') ? 9 : 0,
    ),
    child: Column(
      children: [
        ConfigurableGlassSurface(
          area: 'inputBlur',
          radius: appearance.flag('floatingInput') ? 24 : 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(17, 11, 10, 10),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xff708aaa).withValues(alpha: .1),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                if (demo.attached)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: InputChip(
                      label: const Text(
                        '灵感笔记.md · 演示',
                        style: TextStyle(fontSize: 10),
                      ),
                      avatar: const Icon(Icons.description_outlined, size: 15),
                      onDeleted: () {
                        demo.attached = false;
                        demo.changed();
                      },
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: input,
                        focusNode: focus,
                        key: const ValueKey('chat-composer-field'),
                        minLines: appearance.text('inputStyle') == 'compact'
                            ? 1
                            : 2,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => send(),
                        onChanged: (_) => hideNavigation(),
                        style: const TextStyle(fontSize: 14, height: 1.65),
                        decoration: const InputDecoration(
                          hintText: '发消息…',
                          filled: false,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '展开输入',
                      onPressed: expandDraft,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.open_in_full,
                        size: 16,
                        color: muted,
                      ),
                    ),
                    if (appearance.text('inputStyle') == 'compact')
                      sendControl(),
                  ],
                ),
                if (appearance.text('inputStyle') != 'compact')
                  const SizedBox(height: 5),
                if (appearance.text('inputStyle') != 'compact')
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => picker(false),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 16,
                                  color: green,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    demo.model,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '模型与角色选项',
                        onPressed: () => picker(true),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.tune, size: 20, color: muted),
                      ),
                      IconButton(
                        tooltip: '附件即将支持',
                        onPressed: null,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add, size: 23, color: muted),
                      ),
                      const SizedBox(width: 4),
                      sendControl(),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ChatStatusBar(conversation: demo.conversations[demo.conversation]),
      ],
    ),
  );

  Widget sendControl() => SkiGlassButton(
    accent: true,
    onPressed: demo.streaming ? demo.stop : send,
    icon: demo.streaming ? Icons.stop_rounded : Icons.arrow_upward,
    tooltip: demo.streaming ? '停止生成' : '发送消息',
  );

  void voiceInput() => showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 48, color: green),
          const SizedBox(height: 16),
          label('语音输入演示', size: 21, weight: FontWeight.w600),
          const SizedBox(height: 9),
          label('不请求麦克风权限，点按按钮填入示例文字。', size: 12, color: muted),
          const SizedBox(height: 22),
          actionButton('模拟转写', Icons.mic_none, () {
            input.text = '今天想和你聊聊我的新想法。';
            Navigator.pop(c);
            focus.requestFocus();
            setState(() {});
          }, filled: true),
        ],
      ),
    ),
  );
  void expandDraft() {
    final draft = TextEditingController(text: input.text);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑消息'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: draft,
            minLines: 7,
            maxLines: 12,
            decoration: const InputDecoration(hintText: '在这里慢慢写…'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              input.text = draft.text;
              Navigator.pop(c);
              setState(() {});
            },
            child: const Text('保留草稿'),
          ),
        ],
      ),
    );
  }

  Widget emptyState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 65, horizontal: 20),
    child: Column(
      children: [
        CircleAvatar(
          radius: 35,
          backgroundColor: mist,
          child: Icon(demo.role.icon, size: 33, color: green),
        ),
        const SizedBox(height: 24),
        label('你好，我是 ${demo.role.name}', size: 23, weight: FontWeight.w500),
        const SizedBox(height: 10),
        label(
          demo.activeConnection == null
              ? (demo.useBeta ? '先检查内测状态，继续你的对话。' : '登录中转站或使用自己的模型连接。')
              : '想聊点什么？我在这里。',
          size: 13,
          color: muted,
        ),
        if (demo.activeConnection == null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: demo.useBeta
                ? openModels
                : () => Navigator.of(
                    context,
                  ).pushReplacementNamed('/settings/account'),
            icon: const Icon(Icons.login, size: 18),
            label: Text(demo.useBeta ? '检查内测状态' : '登录中转站'),
          ),
        ],
        const SizedBox(height: 30),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final text in ['聊聊今天', '记录一个想法', '一起做个计划'])
              ActionChip(
                label: Text(text, style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  input.text = text;
                  focus.requestFocus();
                },
              ),
          ],
        ),
      ],
    ),
  );

  Widget message(Message m, int i) {
    keys.putIfAbsent(m, () => GlobalKey());
    final avatar = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: m.user ? const Color(0xffcce6fa) : mist,
        borderRadius: BorderRadius.circular(
          appearance.flag('squareAvatars') ? 7 : 16,
        ),
      ),
      child: Icon(
        m.user ? Icons.person_rounded : demo.role.icon,
        color: green,
        size: m.user ? 23 : 18,
      ),
    );
    final bubble = ChatBubbleSurface(
      user: m.user,
      backdropKey: m.user ? _userBackdrop : _replyBackdrop,
      child: SelectableText(
        m.text.isEmpty
            ? (m.status == 'pending'
                  ? '正在思考…'
                  : m.status == 'cancelled'
                  ? '已停止生成'
                  : '未收到回复')
            : m.text,
        style: chatMessageStyle(context, m.user),
      ),
    );
    return Padding(
      key: keys[m],
      padding: EdgeInsets.only(bottom: demo.compact ? 14 : 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: m.user
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!m.user && appearance.flag('avatars')) ...[
            avatar,
            const SizedBox(width: 9),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: m.user
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                bubble,
                if (m.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      children: [
                        Text(
                          m.error!,
                          style: TextStyle(
                            fontSize: 11,
                            color: m.status == 'failed'
                                ? Theme.of(context).colorScheme.error
                                : muted,
                          ),
                        ),
                        if (!demo.streaming && i == demo.messages.length - 1)
                          TextButton.icon(
                            onPressed: demo.regenerate,
                            icon: const Icon(Icons.refresh, size: 15),
                            label: const Text(
                              '重试',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (appearance.flag('showThinking') &&
                    m.thinking?.isNotEmpty == true)
                  ExpansionTile(
                    title: label('思考过程', size: 11),
                    children: [Text(m.thinking!)],
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (m.user && appearance.flag('showUser'))
                      label('我', size: 10, color: muted),
                    if (!m.user && appearance.flag('showModel'))
                      label(m.modelName ?? '模型 —', size: 10, color: muted),
                    if (!m.user && appearance.flag('showProvider'))
                      label(m.provider ?? '供应商 —', size: 10, color: muted),
                    if (!m.user && appearance.flag('showTokens'))
                      label('Token ${m.tokens ?? '—'}', size: 10, color: muted),
                    if (!m.user && appearance.flag('showElapsed'))
                      label(
                        m.elapsedMs == null
                            ? '耗时 —'
                            : '${(m.elapsedMs! / 1000).toStringAsFixed(2)} s',
                        size: 10,
                        color: muted,
                      ),
                    if (appearance.flag('showTime'))
                      label(
                        '${m.created.hour.toString().padLeft(2, '0')}:${m.created.minute.toString().padLeft(2, '0')}',
                        size: 10,
                        color: muted,
                      ),
                  ],
                ),
                if (!m.user)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 4),
                      if (appearance.flag('showRole'))
                        label(demo.role.name, size: 10, color: muted),
                      if (m.bookmarked) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.bookmark, size: 12, color: green),
                      ],
                      PopupMenuButton<String>(
                        tooltip: '消息菜单 ${i + 1}',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 17,
                        icon: const Icon(Icons.more_horiz, color: muted),
                        onSelected: (v) async {
                          if (v == 'save') {
                            m.bookmarked = !m.bookmarked;
                            demo.changed();
                            demo.saveChats();
                          } else if (v == 'copy') {
                            await Clipboard.setData(
                              ClipboardData(text: m.text),
                            );
                            if (mounted) toast(context, '消息已复制');
                          } else if (v == 'retry') {
                            follow = true;
                            demo.regenerate();
                          } else {
                            input.text = m.text;
                            focus.requestFocus();
                            setState(() {});
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'copy',
                            child: Text('复制消息'),
                          ),
                          PopupMenuItem(
                            value: 'save',
                            child: Text(m.bookmarked ? '取消收藏' : '收藏消息'),
                          ),
                          const PopupMenuItem(
                            value: 'quote',
                            child: Text('引用到输入框'),
                          ),
                          if (i == demo.messages.length - 1 && !demo.streaming)
                            const PopupMenuItem(
                              value: 'retry',
                              child: Text('重新生成'),
                            ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (m.user && appearance.flag('avatars')) ...[
            const SizedBox(width: 9),
            avatar,
          ],
        ],
      ),
    );
  }
}

class NavigationTicks extends CustomPainter {
  NavigationTicks(this.count, this.selected);
  final int count, selected;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ticks = math.max(count, 12);
    for (int i = 0; i < ticks; i++) {
      final a = i / ticks * math.pi * 2;
      final start = center + Offset(math.cos(a), math.sin(a)) * 68;
      final end = center + Offset(math.cos(a), math.sin(a)) * 79;
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = (i / ticks * count).floor() == selected
              ? green
              : muted.withValues(alpha: .3)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(NavigationTicks old) =>
      old.count != count || old.selected != selected;
}
