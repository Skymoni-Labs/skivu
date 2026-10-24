import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'state.dart';
import 'widgets.dart';
import 'glass.dart';
import 'chat_bubble_surface.dart';
import 'chat_backdrop.dart';
import 'chat_status_bar.dart';
import 'appearance.dart';
import 'chat_controls.dart';
import 'relay_account.dart';
import 'chat_message_dial.dart';
import 'character_avatar.dart';
import 'assistant_reply_layout.dart';
import 'message_info_row.dart';
import 'chat_extras.dart';
import 'sticker_library_page.dart';
import 'launch.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.openWorkspace,
    required this.openCall,
    this.openModels,
    this.backdropAnchor,
  });
  final VoidCallback openWorkspace, openCall;
  final VoidCallback? openModels;
  final GlobalKey? backdropAnchor;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final keys = <Message, GlobalKey>{};
  final _composerMeasureKey = GlobalKey();
  double _composerExtent = 0;
  double? _viewportExtent;
  bool _composerMeasureQueued = false;
  Timer? navTimer;
  bool showNav = false, follow = true;
  bool _followQueued = false;
  int _bottomSeek = 0;
  int oldCount = 0, _centeredIndex = 0;
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
    _queueChatReader();
    _queueComposerMeasure();
  }

  void _queueComposerMeasure() {
    if (_composerMeasureQueued) return;
    _composerMeasureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerMeasureQueued = false;
      if (!mounted) return;
      final box = _composerMeasureKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final extent = box.size.height;
      if ((extent - _composerExtent).abs() < .5) return;
      final wasMeasured = _composerExtent > 0;
      setState(() => _composerExtent = extent);
      if (wasMeasured && follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && follow && scroll.hasClients)
            scroll.jumpTo(scroll.position.maxScrollExtent);
        });
      }
    });
  }

  void update() {
    if (!mounted) return;
    final current = demo.conversations[demo.conversation];
    if (!identical(current, _conversation)) {
      _bottomSeek++;
      _conversation = current;
      _queueChatReader();
      input.text = current.draft;
      keys.clear();
      follow = true;
      showNav = false;
    }
    if (demo.messages.length != oldCount || (demo.streaming && follow)) {
      oldCount = demo.messages.length;
      if (follow && !_followQueued) {
        _followQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _followQueued = false;
          if (mounted && follow && scroll.hasClients) {
            if (demo.streaming) {
              scroll.jumpTo(scroll.position.maxScrollExtent);
            } else {
              scroll.animateTo(
                scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
              );
            }
          }
        });
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    demo.setChatReader(this, null);
    demo.removeListener(update);
    input.dispose();
    focus.dispose();
    scroll.dispose();
    navTimer?.cancel();
    super.dispose();
  }

  void _queueChatReader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) demo.setChatReader(this, _conversation.id);
    });
  }

  void hideNavigation() {
    navTimer?.cancel();
    if (mounted)
      setState(() {
        showNav = false;
      });
  }

  void revealNavigation() {
    if (focus.hasFocus || demo.messages.isEmpty) return;
    navTimer?.cancel();
    setState(() => showNav = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final index = selectedMessageIndex();
        if (index != _centeredIndex) setState(() => _centeredIndex = index);
      }
    });
    navTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) hideNavigation();
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
      showNav = false;
      follow = false;
    });
  }

  void latest() {
    hideNavigation();
    setState(() => follow = true);
    _seekBottom(++_bottomSeek);
  }

  void _seekBottom(
    int token, {
    int attempts = 0,
    int stable = 0,
    double? previousEnd,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _bottomSeek || !follow || !scroll.hasClients)
        return;
      final end = scroll.position.maxScrollExtent;
      final reached = (scroll.offset - end).abs() < .5;
      final settled =
          reached && previousEnd != null && (end - previousEnd).abs() < .5
          ? stable + 1
          : 0;
      if (!reached) scroll.jumpTo(end);
      // Lazy children revise maxScrollExtent when a long reply is laid out.
      // Stop only after the actual end stays reached across layout frames.
      if (settled < 2 && attempts < 100) {
        _seekBottom(
          token,
          attempts: attempts + 1,
          stable: settled,
          previousEnd: end,
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
    if (demo.messages.lastOrNull?.status != 'queued') focus.unfocus();
    demo.saveChats();
  }

  void openModels() {
    if (demo.useAccount) {
      Navigator.of(context).pushReplacementNamed(
        relayAccount.funding == 'beta' ? '/settings/beta' : '/settings/account',
      );
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

  void picker(bool role) =>
      role ? showChatControls(context) : showChatModelPicker(context);
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
                                  : Icon(
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

  void attachments() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('相册与拍照'),
          onTap: () async {
            Navigator.pop(sheet);
            follow = true;
            await showChatMediaActions(context);
          },
        ),
        ListTile(
          leading: const Icon(Icons.graphic_eq),
          title: const Text('语音识别'),
          onTap: () async {
            Navigator.pop(sheet);
            follow = true;
            await composeChatMedia(context, photo: false, initiallyReal: true);
          },
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('照片描述'),
          onTap: () async {
            Navigator.pop(sheet);
            follow = true;
            await composeChatMedia(context, photo: true);
          },
        ),
        ListTile(
          leading: const Icon(Icons.emoji_emotions_outlined),
          title: const Text('表情包'),
          subtitle: const Text('发送自定义分组中的表情'),
          onTap: () async {
            Navigator.pop(sheet);
            follow = true;
            await showStickerPicker(context);
          },
        ),
        const ListTile(
          leading: Icon(Icons.attach_file),
          title: Text('文件'),
          trailing: Text('即将开放'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        // Messages continue underneath the floating composer. Their scroll
        // padding reserves its measured height without cutting a dark seam.
        LaunchReveal(
          part: LaunchPart.content,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) {
              if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
              final previous = _viewportExtent;
              _viewportExtent = n.metrics.viewportDimension;
              if (previous != null &&
                  (previous - _viewportExtent!).abs() > .5 &&
                  follow) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && follow && scroll.hasClients)
                    scroll.jumpTo(scroll.position.maxScrollExtent);
                });
              }
              return false;
            },
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
                // Frost samples the live scene. Caching each message as a
                // separate scrolling layer can retain an unfiltered backdrop
                // while its transform changes on Android's renderer.
                addRepaintBoundaries: false,
                padding: EdgeInsets.fromLTRB(
                  appearance.flag('wideChat') ? 8 : 14,
                  appToolbarHeight + 20 + MediaQuery.paddingOf(context).top,
                  appearance.flag('wideChat') ? 8 : 14,
                  24 + _composerExtent,
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
        ),
        if (demo.messages.isNotEmpty)
          Positioned.fill(
            bottom: _composerExtent,
            child: LayoutBuilder(
              builder: (context, bounds) => ChatMessageDial(
                key: ObjectKey(_conversation),
                visible: showNav,
                viewportHeight: bounds.maxHeight,
                currentTimestamp: _centeredIndex,
                loadEntries: () async => [
                  for (int i = 0; i < demo.messages.length; i++)
                    ChatMessageLocatorPreview(
                      timestamp: i,
                      sender: demo.messages[i].user ? 'user' : 'assistant',
                      previewContent: demo.messages[i].text,
                      messageIndex: i,
                    ),
                ],
                onOpenLocator: messageNavigator,
                onLatest: latest,
                showLatest: !follow && !focus.hasFocus,
                onJump: locate,
                onHidden: hideNavigation,
                senderName: (sender) => sender == 'user' ? '你' : demo.role.name,
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _queueComposerMeasure();
              return true;
            },
            child: SizeChangedLayoutNotifier(
              key: _composerMeasureKey,
              child: ChatComposerBackdrop(
                sceneAnchor: widget.backdropAnchor,
                topInset: 6,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
              ),
            ),
          ),
        ),
      ],
    ),
  );

  int selectedMessageIndex() {
    if (!scroll.hasClients) return 0;
    final center =
        scroll.offset +
        (scroll.position.viewportDimension - _composerExtent).clamp(
              0.0,
              double.infinity,
            ) /
            2;
    double distance = double.infinity;
    int found = 0;
    for (int i = 0; i < demo.messages.length; i++) {
      final ctx = keys[demo.messages[i]]?.currentContext;
      final render = ctx?.findRenderObject();
      if (render is RenderBox && render.hasSize) {
        final dy = render.localToGlobal(Offset.zero).dy;
        final host = context.findRenderObject() as RenderBox?;
        final local =
            dy -
            (host?.localToGlobal(Offset.zero).dy ?? 0) +
            scroll.offset +
            render.size.height / 2;
        if ((local - center).abs() < distance) {
          distance = (local - center).abs();
          found = i;
        }
      }
    }
    return found;
  }

  Widget composer() => Padding(
    key: const ValueKey('chat-composer'),
    padding: EdgeInsets.fromLTRB(
      appearance.flag('floatingInput') ? 10 : 0,
      6,
      appearance.flag('floatingInput') ? 10 : 0,
      appearance.flag('floatingInput') ? 9 : 0,
    ),
    child: Column(
      children: [
        LaunchReveal(
          part: LaunchPart.composer,
          radius: appearance.flag('floatingInput') ? 24 : 0,
          child: ConfigurableGlassSurface(
            area: 'inputBlur',
            radius: appearance.flag('floatingInput') ? 24 : 0,
            child: Container(
              color: Colors.transparent,
              padding: const EdgeInsets.fromLTRB(17, 11, 10, 10),
              child: Column(
                children: [
                  QueuedSendBar(
                    input: input,
                    beforeConfirm: () => follow = true,
                  ),
                  if (demo.attached)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: InputChip(
                        label: const Text(
                          '灵感笔记.md · 演示',
                          style: TextStyle(fontSize: 10),
                        ),
                        avatar: const Icon(
                          Icons.description_outlined,
                          size: 15,
                        ),
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
                          cursorColor: appearance.textColor('inputText'),
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.65,
                            color: appearance.textColor('inputText'),
                            fontFamily: appearance.fontFamily('inputFont'),
                            fontFamilyFallback: const ['SkiSans'],
                          ),
                          decoration: InputDecoration(
                            hintText: '发消息…',
                            hintStyle: TextStyle(
                              color: appearance
                                  .textColor('inputText')
                                  .withValues(alpha: .65),
                            ),
                            filled: false,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 4,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '展开输入',
                        onPressed: expandDraft,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.open_in_full, size: 16, color: muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
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
                                Icon(
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
                        tooltip: '对话设置',
                        onPressed: () => picker(true),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.tune, size: 20, color: muted),
                      ),
                      IconButton(
                        tooltip: '添加内容',
                        onPressed: attachments,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.add, size: 23, color: muted),
                      ),
                      const SizedBox(width: 4),
                      sendControl(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (appearance.flag('showUsage')) ...[
          const SizedBox(height: 6),
          ChatStatusBar(conversation: demo.conversations[demo.conversation]),
        ],
      ],
    ),
  );

  Widget sendControl() => SkiGlassButton(
    accent: true,
    onPressed: demo.streaming ? demo.stop : send,
    icon: demo.streaming ? Icons.stop_rounded : Icons.arrow_upward,
    tooltip: demo.streaming
        ? '停止生成'
        : demo.conversations[demo.conversation].confirmBeforeReply
        ? '暂存这条消息'
        : '发送消息',
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
            style: TextStyle(
              color: appearance.textColor('inputText'),
              fontFamily: appearance.fontFamily('inputFont'),
              fontFamilyFallback: const ['SkiSans'],
            ),
            cursorColor: appearance.textColor('inputText'),
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
          child: IconButton(
            tooltip: '编辑角色卡',
            onPressed: () {
              demo.editCurrentRole();
              Navigator.of(context).pushReplacementNamed('/characters/edit');
            },
            icon: CharacterAvatar(persona: demo.role, size: 52),
          ),
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

  Future<void> deleteRound(Message message) async {
    final chatId = _conversation.id;
    final round = demo.roundMessages(chatId, message);
    if (round.isEmpty) return;
    final question = round.first.user ? round.first.text : null;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除本轮对话？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将删除${question == null ? '这段回复' : '本轮提问和回复'}，共 ${round.length} 条消息。其他轮次会保留，后续上下文不再包含这些内容。删除后无法恢复。',
            ),
            if (question != null) ...[
              const SizedBox(height: 12),
              Text(question, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            if (round.any((m) => m.status == 'pending')) ...[
              const SizedBox(height: 12),
              const Text('正在生成的本轮回复会同时停止。'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除本轮'),
          ),
        ],
      ),
    );
    if (yes == true && mounted && demo.deleteRound(chatId, message)) {
      keys.removeWhere((m, _) => !demo.messages.contains(m));
      _centeredIndex = demo.messages.isEmpty
          ? 0
          : _centeredIndex.clamp(0, demo.messages.length - 1);
      hideNavigation();
      toast(context, '本轮对话已删除');
    }
  }

  Widget message(Message m, int i) {
    final layout = appearance.text('assistantBubbleLayout');
    final fill = !m.user && layout != 'centered';
    final hasThinking =
        appearance.flag('showThinking') && m.thinking?.isNotEmpty == true;
    keys.putIfAbsent(m, () => GlobalKey());
    final avatar = Tooltip(
      message: m.user ? '编辑我的角色卡' : '编辑对话角色卡',
      child: InkWell(
        onTap: () {
          if (m.user) {
            editUserCard(context);
          } else {
            demo.editCurrentRole();
            Navigator.of(context).pushReplacementNamed('/characters/edit');
          }
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: m.user ? const Color(0xffcce6fa) : mist,
            borderRadius: BorderRadius.circular(
              appearance.flag('squareAvatars') ? 7 : 16,
            ),
          ),
          child: m.user
              ? UserAvatar(square: appearance.flag('squareAvatars'))
              : CharacterAvatar(
                  persona: demo.role,
                  square: appearance.flag('squareAvatars'),
                ),
        ),
      ),
    );
    final bubble = ChatBubbleSurface(
      key: ValueKey('message-bubble-$i'),
      user: m.user,
      contentPadding: AssistantReplyLayout.bubblePadding(
        m.user ? 'centered' : layout,
      ),
      child: m.kind != 'text'
          ? TypedMessageBody(message: m)
          : SelectableText(
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
    final content = Column(
      crossAxisAlignment: fill
          ? CrossAxisAlignment.stretch
          : m.user
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        bubble,
        if (m.status == 'queued')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                label('待确认', size: 11),
                IconButton(
                  tooltip: '移除此条待发送消息',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () => demo.deleteRound(
                    demo.conversations[demo.conversation].id,
                    m,
                  ),
                ),
              ],
            ),
          ),
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
                    label: const Text('重试', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ),
        if (!m.user)
          MessageInfoRow(key: ValueKey('message-info-$i'), message: m)
        else
          Wrap(
            spacing: 8,
            children: [
              if (appearance.flag('showUser'))
                label('我', size: 10, color: muted),
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
                icon: Icon(Icons.more_horiz, color: muted),
                onSelected: (v) async {
                  if (v == 'save') {
                    m.bookmarked = !m.bookmarked;
                    demo.changed();
                    demo.saveChats();
                  } else if (v == 'copy') {
                    await Clipboard.setData(ClipboardData(text: m.text));
                    if (mounted) toast(context, '消息已复制');
                  } else if (v == 'retry') {
                    follow = true;
                    demo.regenerate();
                  } else if (v == 'delete-round') {
                    await deleteRound(m);
                  } else {
                    input.text = m.text;
                    focus.requestFocus();
                    setState(() {});
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'copy', child: Text('复制消息')),
                  PopupMenuItem(
                    value: 'save',
                    child: Text(m.bookmarked ? '取消收藏' : '收藏消息'),
                  ),
                  const PopupMenuItem(value: 'quote', child: Text('引用到输入框')),
                  const PopupMenuItem(
                    value: 'delete-round',
                    child: Text('删除本轮对话'),
                  ),
                  if (i == demo.messages.length - 1 && !demo.streaming)
                    const PopupMenuItem(value: 'retry', child: Text('重新生成')),
                ],
              ),
            ],
          ),
      ],
    );
    return Padding(
      key: keys[m],
      padding: EdgeInsets.only(bottom: demo.compact ? 14 : 24),
      child: !m.user
          ? AssistantReplyLayout(
              layout: layout,
              wide: appearance.flag('wideChat'),
              avatar: appearance.flag('avatars') ? avatar : null,
              thinking: hasThinking ? m.thinking : null,
              child: content,
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: content),
                if (appearance.flag('avatars')) ...[
                  const SizedBox(width: 9),
                  avatar,
                ],
              ],
            ),
    );
  }
}
