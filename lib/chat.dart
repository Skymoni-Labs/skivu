import 'dart:async';
import 'package:flutter/material.dart';
import 'cloud_storage_page.dart';
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
import 'chat_thinking_toggle.dart';
import 'relay_account.dart';
import 'chat_message_dial.dart';
import 'character_avatar.dart';
import 'assistant_reply_layout.dart';
import 'thinking_disclosure.dart';
import 'message_info_row.dart';
import 'chat_extras.dart';
import 'sticker_library_page.dart';
import 'launch.dart';
import 'open_plugin_companion_ui.dart';
import 'personal_space.dart';
import 'personal_space_ui.dart';
import 'chat_quote.dart';
import 'scroll_glass_activity.dart';
import 'scroll_benchmark.dart';
import 'cloud_conversations.dart';
import 'cloud_execution_disclosure.dart';
import 'cloud_companion_motion.dart';
import 'embedded_engine_settings.dart';
import 'device_engine.dart';
import 'task_result_card.dart';
import 'cloud_file_card.dart';
import 'task_plans.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.openWorkspace,
    required this.openCall,
    this.openModels,
    this.backdropAnchor,
    this.onModuleChanged,
  });
  final VoidCallback openWorkspace, openCall;
  final VoidCallback? openModels;
  final GlobalKey? backdropAnchor;
  final ValueChanged<int>? onModuleChanged;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with SingleTickerProviderStateMixin {
  int _module = 0;
  String? _ordinaryChatId;
  bool get _chatVisible => _module == 0 || _module == 4;
  late final AnimationController _moduleFade;
  late final Animation<double> _moduleProgress;
  late final Animation<Offset> _moduleSlide;
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final keys = <Message, GlobalKey>{};
  final _expandedExecutionIds = <String>{};
  final _openingResultIds = <String>{};
  final _savingTaskIds = <String>{};
  final _composerMeasureKey = GlobalKey();
  double _composerExtent = 0;
  double? _viewportExtent;
  bool _composerMeasureQueued = false;
  Timer? navTimer;
  final _navigationRevision = ValueNotifier(0);
  bool showNav = false, follow = true;
  bool _followQueued = false;
  int _bottomSeek = 0;
  int _messageSeek = 0;
  int oldCount = 0, _centeredIndex = 0;
  late Conversation _conversation;
  int _draftRevision = 0;
  @override
  void initState() {
    super.initState();
    cloudChats.attach();
    _module = demo.isCloudChat ? 4 : 0;
    _moduleFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 1,
    );
    _moduleProgress = _moduleFade.drive(CurveTween(curve: Curves.easeOutCubic));
    _moduleSlide = Tween<Offset>(
      begin: const Offset(0, .008),
      end: Offset.zero,
    ).animate(_moduleProgress);
    _conversation = demo.conversations[demo.conversation];
    input.text = _conversation.draft;
    input.addListener(() => demo.saveDraft(_conversation, input.text));
    focus.addListener(() {
      if (focus.hasFocus) hideNavigation();
    });
    demo.addListener(update);
    personalSpace.addListener(_personalChanged);
    taskPlans.addListener(_plansChanged);
    _queueChatReader();
    _queueComposerMeasure();
    _reportModule();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _plansChanged();
    });
  }

  void _reportModule() {
    final selected = _module;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _module == selected)
        widget.onModuleChanged?.call(selected);
    });
  }

  void _personalChanged() {
    if (mounted && _module != 0) setState(() {});
  }

  void _plansChanged() {
    if (!mounted) return;
    setState(() {});
    final requestedGoal = taskPlans.pendingAssistantGoal,
        requestedTask = taskPlans.pendingAssistantTaskId;
    if (requestedGoal != null && requestedTask != null) {
      taskPlans.pendingAssistantGoal = null;
      taskPlans.pendingAssistantTaskId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectModule(4);
          if (!demo.send(
            requestedGoal,
            taskReference: requestedTask,
            immediate: true,
          ))
            toast(context, '当前无法开始处理，请稍后从这条任务继续。');
        }
      });
    }
    final id = taskPlans.pendingTaskId;
    if (id == null) return;
    taskPlans.pendingTaskId = null;
    final task = personalSpace.task(id);
    if (task == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _selectModule(2);
        editPersonalRecord(context, store: personalSpace, record: task);
      }
    });
  }

  void _selectModule(int value) {
    if (_module == value) return;
    if (value == 4 && !demo.isCloudChat) {
      _ordinaryChatId = _conversation.id;
      demo.openCloudChat();
    } else if (value == 0 && demo.isCloudChat) {
      final normal =
          demo.conversations
              .where(
                (c) => c.id == _ordinaryChatId && c.personaId != cloudPersonaId,
              )
              .firstOrNull ??
          demo.conversations
              .where((c) => c.personaId != cloudPersonaId)
              .firstOrNull;
      if (normal != null) {
        demo.selectChat(demo.conversations.indexOf(normal));
      } else {
        demo.newChat(personaId: demo.personas.firstWhere((p) => !p.isCloud).id);
      }
    }
    focus.unfocus();
    navTimer?.cancel();
    setState(() {
      _module = value;
      showNav = false;
    });
    widget.onModuleChanged?.call(value);
    if (MediaQuery.disableAnimationsOf(context) ||
        appearance.flag('reduceMotion') ||
        (demo.prefs['减少动态效果'] ?? false)) {
      _moduleFade.value = 1;
    } else {
      _moduleFade.forward(from: 0);
    }
    _queueChatReader();
    _queueComposerMeasure();
  }

  Widget _moduleContent(Widget child) => FadeTransition(
    opacity: _moduleProgress,
    child: SlideTransition(position: _moduleSlide, child: child),
  );

  void _personalDraft(String text) {
    // The existing conversation keeps its draft; personal-page suggestions
    // append to it and never send or create a separate plugin conversation.
    final previous = input.text;
    _selectModule(demo.isCloudChat ? 4 : 0);
    input.text = previous.trim().isEmpty ? text : '$previous\n\n$text';
    input.selection = TextSelection.collapsed(offset: input.text.length);
    focus.requestFocus();
  }

  void _taskDraft(PersonalRecord task) {
    _selectModule(4);
    setState(() => _conversation.draftTaskId = task.id);
    if (input.text.trim().isEmpty) input.text = '帮我处理这条任务：';
    input.selection = TextSelection.collapsed(offset: input.text.length);
    demo.saveChats();
    focus.requestFocus();
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
      _module = demo.isCloudChat ? 4 : 0;
      _reportModule();
      _moduleFade.stop();
      _moduleFade.value = 1;
      _bottomSeek++;
      _messageSeek++;
      _conversation = current;
      _draftRevision = current.draftRevision;
      _queueChatReader();
      input.text = current.draft;
      keys.clear();
      _expandedExecutionIds.clear();
      follow = true;
      showNav = false;
    } else if (_draftRevision != current.draftRevision) {
      _draftRevision = current.draftRevision;
      if (input.text != current.draft) input.text = current.draft;
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
    personalSpace.removeListener(_personalChanged);
    taskPlans.removeListener(_plansChanged);
    _moduleFade.dispose();
    input.dispose();
    focus.dispose();
    scroll.dispose();
    _navigationRevision.dispose();
    navTimer?.cancel();
    super.dispose();
  }

  void _queueChatReader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        demo.setChatReader(this, _chatVisible ? _conversation.id : null);
    });
  }

  void hideNavigation() {
    navTimer?.cancel();
    if (mounted && showNav) {
      showNav = false;
      _navigationRevision.value++;
    }
  }

  void revealNavigation({bool scrolling = false}) {
    final changed = !showNav || follow;
    follow = false;
    if (focus.hasFocus || demo.messages.isEmpty) return;
    navTimer?.cancel();
    navTimer = null;
    if (changed) {
      showNav = true;
      _navigationRevision.value++;
    }
    if (!scrolling)
      navTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) hideNavigation();
      });
  }

  void locate(int index) {
    if (demo.messages.isEmpty) return;
    final target = demo.messages[index.clamp(0, demo.messages.length - 1)];
    _bottomSeek++;
    setState(() {
      showNav = false;
      follow = false;
      if (demo.isCloudChat && target.toolReceipt) {
        final row = cloudTranscriptRows(
          demo.messages,
          cloud: true,
        ).firstWhere((row) => row.messages.contains(target));
        _expandedExecutionIds.add(row.first.id);
      }
    });
    _seekMessage(target, ++_messageSeek);
  }

  // A lazy list has no RenderBox for an offscreen message. Seek using the
  // currently laid-out indexes, then align the exact message once it exists.
  void _seekMessage(Message target, int token, {int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _messageSeek || !scroll.hasClients) return;
      // Folded tool records share one visible row. Estimate distances using
      // displayed rows, otherwise a long tool run can make the seek overshoot.
      final indexes = <Message, int>{
        for (final (index, row) in cloudTranscriptRows(
          demo.messages,
          cloud: demo.isCloudChat,
        ).indexed)
          for (final message in row.allMessages) message: index,
      };
      final targetIndex = indexes[target];
      if (targetIndex == null) return;
      final context = keys[target]?.currentContext;
      if (context != null) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: .13,
          ),
        );
        return;
      }
      final visible = <(int, double)>[];
      final anchors = <GlobalKey>{};
      for (final entry in keys.entries) {
        if (!anchors.add(entry.value)) continue;
        final box = entry.value.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize && box.attached) {
          final index = indexes[entry.key];
          if (index != null) visible.add((index, box.size.height));
        }
      }
      visible.sort((a, b) => a.$1.compareTo(b.$1));
      final mean = visible.isEmpty
          ? 160.0
          : visible.fold<double>(0, (sum, entry) => sum + entry.$2) /
                visible.length;
      final anchor = visible.isEmpty ? 0 : visible[visible.length ~/ 2].$1;
      final distance = (targetIndex - anchor) * mean;
      final position = scroll.position;
      final next = (scroll.offset + distance)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((next - scroll.offset).abs() > .5) scroll.jumpTo(next);
      if (attempt < 60) {
        _seekMessage(target, token, attempt: attempt + 1);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void latest() {
    _messageSeek++;
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
    if (!_chatVisible) _selectModule(demo.isCloudChat ? 4 : 0);
    hideNavigation();
    follow = true;
    if (!demo.send(
      value,
      quotes: List.of(_conversation.draftQuotes),
      taskReference: _conversation.draftTaskId,
    )) {
      if (demo.lastError != null) toast(context, demo.lastError!);
      if (demo.activeConnection == null) openModels();
      return;
    }
    _conversation.draftTaskId = null;
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
        ListTile(
          leading: Icon(Icons.attach_file),
          title: const Text('手机文件'),
          subtitle: const Text('导入已授权文件到小云项目'),
          onTap: () {
            Navigator.pop(sheet);
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CloudStoragePage()),
            );
          },
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final transcript = cloudTranscriptRows(
      demo.messages,
      cloud: demo.isCloudChat,
    );
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Messages continue underneath the floating composer. Their scroll
          // padding reserves its measured height without cutting a dark seam.
          LaunchReveal(
            part: LaunchPart.content,
            child: _moduleContent(
              Visibility(
                visible: _chatVisible,
                maintainState: true,
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (n) {
                    if (n.depth != 0 || n.metrics.axis != Axis.vertical)
                      return false;
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
                      if (n.depth != 0 || n.metrics.axis != Axis.vertical)
                        return false;
                      if ((n is ScrollStartNotification &&
                              n.dragDetails != null) ||
                          (n is ScrollUpdateNotification &&
                              n.dragDetails != null) ||
                          (n is UserScrollNotification &&
                              n.direction != ScrollDirection.idle)) {
                        revealNavigation(scrolling: true);
                      } else if (n is ScrollEndNotification &&
                          showNav &&
                          !follow)
                        revealNavigation();
                      return false;
                    },
                    child: ScrollGlassSurface(
                      child: ListView.builder(
                        controller: scroll,
                        // The frost must follow scene coordinates as rows move.
                        // ChatBubbleSurface retains text/media separately, leaving
                        // the wallpaper plane live instead of caching the whole row.
                        addRepaintBoundaries: false,
                        padding: EdgeInsets.fromLTRB(
                          appearance.flag('wideChat') ? 8 : 14,
                          appToolbarHeight +
                              20 +
                              MediaQuery.paddingOf(context).top,
                          appearance.flag('wideChat') ? 8 : 14,
                          24 + _composerExtent,
                        ),
                        itemCount: demo.messages.isEmpty
                            ? 1
                            : transcript.length +
                                  1 +
                                  (!demo.isCloudChat &&
                                          demo.streaming &&
                                          appearance.flag('showStatus')
                                      ? 1
                                      : 0),
                        itemBuilder: (context, index) {
                          if (demo.messages.isEmpty) return emptyState();
                          if (index == 0 && demo.isCloudChat)
                            return cloudHeader();
                          if (index == 0)
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 25),
                              child: Center(
                                child: label(
                                  '与 ${demo.role.name} 的对话',
                                  size: 10,
                                  color: sceneMuted,
                                ),
                              ),
                            );
                          if (index <= transcript.length) {
                            final row = transcript[index - 1];
                            return row.execution
                                ? executionRow(row)
                                : message(row.first, row.index);
                          }
                          return Padding(
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
                                label('正在回复…', size: 10, color: sceneMuted),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!_chatVisible)
            Positioned.fill(
              child: _moduleContent(
                PersonalModulePage(
                  module: _module,
                  topInset:
                      appToolbarHeight + 20 + MediaQuery.paddingOf(context).top,
                  bottomInset: _composerExtent + 24,
                  onDraft: _personalDraft,
                  onTask: _taskDraft,
                  onModule: _selectModule,
                ),
              ),
            ),
          if (ScrollBenchmark.enabled && _chatVisible)
            Positioned(
              top: appToolbarHeight + 12 + MediaQuery.paddingOf(context).top,
              right: 16,
              child: ScrollBenchmark(
                controller: scroll,
                onStart: () => follow = false,
              ),
            ),
          if (_chatVisible && demo.messages.isNotEmpty)
            Positioned.fill(
              bottom: _composerExtent,
              child: LayoutBuilder(
                builder: (context, bounds) => ValueListenableBuilder<int>(
                  valueListenable: _navigationRevision,
                  builder: (_, revision, _) => ChatMessageDial(
                    key: ObjectKey(_conversation),
                    visible: showNav,
                    viewportHeight: bounds.maxHeight,
                    currentTimestamp: _centeredIndex,
                    resolveCurrentTimestamp: selectedMessageIndex,
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
                    senderName: (sender) =>
                        sender == 'user' ? '你' : demo.role.name,
                  ),
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
                  liveContent: appearance.flag('skymoniGlass'),
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
  }

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
      appearance.flag('floatingInput') ? 12 : 0,
      6,
      appearance.flag('floatingInput') ? 12 : 0,
      appearance.flag('floatingInput') ? 9 : 0,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_chatVisible) ...[
          LaunchReveal(
            part: LaunchPart.composer,
            radius: 26,
            child: MainComposerInputSurface(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (demo.isCloudChat) cloudTaskStatus(),
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
                  if (demo.isCloudChat && _conversation.draftTaskId != null)
                    Row(
                      key: const ValueKey('cloud-selected-task'),
                      children: [
                        const Icon(Icons.checklist_outlined, size: 15),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            personalSpace
                                    .task(_conversation.draftTaskId!)
                                    ?.title ??
                                '所选任务已不可用',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _composerControlInk,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '移除任务关联',
                          onPressed: () {
                            setState(() => _conversation.draftTaskId = null);
                            demo.saveChats();
                          },
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  if (_conversation.draftQuotes.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _quoteBadge(
                        _conversation.draftQuotes,
                        draft: true,
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
                            fontWeight: appearance.flag('skymoniGlass')
                                ? FontWeight.w500
                                : null,
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
                                  .withValues(
                                    alpha: appearance.flag('skymoniGlass')
                                        ? .8
                                        : .65,
                                  ),
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
                        icon: Icon(
                          Icons.open_in_full,
                          size: 16,
                          color: _composerControlInk,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: ChatThinkingToggle(),
                  ),
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
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: appearance.flag('skymoniGlass')
                                          ? appearance.textColor('inputText')
                                          : null,
                                      fontWeight:
                                          appearance.flag('skymoniGlass')
                                          ? FontWeight.w500
                                          : null,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: _composerControlInk,
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
                        icon: Icon(
                          Icons.tune,
                          size: 20,
                          color: _composerControlInk,
                        ),
                      ),
                      IconButton(
                        tooltip: '添加内容',
                        onPressed: attachments,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.add,
                          size: 23,
                          color: _composerControlInk,
                        ),
                      ),
                      const SizedBox(width: 4),
                      sendControl(),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (appearance.flag('showUsage')) ...[
            const SizedBox(height: 4),
            ChatStatusBar(conversation: _conversation),
          ],
          const SizedBox(height: 6),
        ],
        PersonalModuleBar(selected: _module, onSelected: _selectModule),
      ],
    ),
  );

  Widget sendControl() => IgnorePointer(
    ignoring: demo.thinkingUpdatePending && !demo.streaming,
    child: Opacity(
      opacity: demo.thinkingUpdatePending && !demo.streaming ? .45 : 1,
      child: SkiGlassButton(
        skymoni: true,
        accent: true,
        onPressed: demo.streaming ? demo.stop : send,
        icon: demo.streaming ? Icons.stop_rounded : Icons.arrow_upward,
        tooltip: demo.streaming
            ? '停止生成'
            : demo.thinkingUpdatePending
            ? '正在保存思考设置'
            : demo.conversations[demo.conversation].confirmBeforeReply
            ? '暂存这条消息'
            : '发送消息',
      ),
    ),
  );

  Widget cloudTaskStatus() {
    final assistant = cloudChats.engineFor(_conversation);
    if (!assistant.running &&
        !assistant.canResume &&
        assistant.phase != 'unknown')
      return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: Text(
            cloudActivityForTask(
              assistant.phase,
              tool: assistant.pending?['tool'] as String?,
            ).label,
            style: TextStyle(fontSize: 12, color: _composerControlInk),
          ),
        ),
        if (assistant.canResume)
          TextButton(
            onPressed: demo.resumeCloud,
            child: Text(
              assistant.phase == 'confirmation' ? '确认再次执行此操作' : '核对授权并继续',
            ),
          ),
        if (assistant.canResume)
          IconButton(
            tooltip: '停止任务',
            onPressed: demo.stop,
            icon: const Icon(Icons.stop_rounded),
          ),
        IconButton(
          tooltip: '手机能力与授权',
          onPressed: openCloudCapabilities,
          icon: const Icon(Icons.phonelink_setup, size: 20),
        ),
      ],
    );
  }

  void openCloudCapabilities() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const EmbeddedEngineSettings()),
  );

  Widget cloudHeader({bool empty = false}) {
    return Padding(
      key: const ValueKey('cloud-chat-header'),
      padding: EdgeInsets.symmetric(vertical: empty ? 30 : 10),
      child: Column(
        children: [
          Text(
            demo.role.name,
            style: TextStyle(fontSize: empty ? 25 : 18, color: sceneInk),
          ),
          const SizedBox(height: 6),
          Text(
            empty ? '把想法放在这里，我们一起动手完成。' : '一起想，也一起动手',
            style: TextStyle(fontSize: 12, color: sceneMuted),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            children: [
              TextButton.icon(
                onPressed: openCloudCapabilities,
                icon: const Icon(Icons.phonelink_setup, size: 17),
                label: const Text('手机能力与授权'),
              ),
              TextButton.icon(
                onPressed: () => _selectModule(2),
                icon: const Icon(Icons.checklist_outlined, size: 17),
                label: const Text('我的任务'),
              ),
              TextButton.icon(
                onPressed: () {
                  demo.editCurrentRole();
                  Navigator.of(
                    context,
                  ).pushReplacementNamed('/characters/edit');
                },
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('角色设置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color get _composerControlInk => appearance.flag('skymoniGlass')
      ? appearance.textColor('inputText').withValues(alpha: .92)
      : muted;

  Widget _quoteBadge(List<ChatQuote> quotes, {bool draft = false}) {
    final foreground = appearance.textColor(draft ? 'inputText' : 'userText');
    final lightText = foreground.computeLuminance() > .45;
    return Container(
      key: draft ? const ValueKey('chat-draft-quote-badge') : null,
      margin: const EdgeInsets.only(top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: lightText
            ? const Color(0xff1e3045).withValues(alpha: .86)
            : Colors.white.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: foreground.withValues(alpha: .14), width: .6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => _showQuotes(quotes, draft: draft),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.comment_outlined,
                    size: 12,
                    color: foreground.withValues(alpha: .9),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${quotes.length} 条引用',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: foreground,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (draft)
            Tooltip(
              message: '移除全部引用',
              child: InkWell(
                onTap: () => demo.removeDraftQuote(_conversation, null),
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: foreground.withValues(alpha: .85),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showQuotes(List<ChatQuote> quotes, {bool draft = false}) {
    final target = _conversation;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: demo,
        builder: (context, _) {
          final rows = draft ? target.draftQuotes : quotes;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .7,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '引用内容 · ${rows.length}',
                    style: const TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 12),
                  for (final q in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  q.sender,
                                  style: TextStyle(fontSize: 12, color: muted),
                                ),
                              ),
                              if (draft)
                                IconButton(
                                  tooltip: '移除此条引用',
                                  onPressed: () => demo.removeDraftQuote(
                                    target,
                                    q.messageId,
                                  ),
                                  icon: const Icon(Icons.close, size: 17),
                                ),
                            ],
                          ),
                          SelectableText(
                            q.text,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: ink,
                            ),
                          ),
                          TextButton(
                            onPressed:
                                target.id == q.chatId &&
                                    target.messages.any(
                                      (m) => m.id == q.messageId,
                                    )
                                ? () {
                                    Navigator.pop(sheetContext);
                                    _selectModule(demo.isCloudChat ? 4 : 0);
                                    locate(
                                      target.messages.indexWhere(
                                        (m) => m.id == q.messageId,
                                      ),
                                    );
                                  }
                                : null,
                            child: const Text('定位原文'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

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

  Widget emptyState() {
    if (demo.isCloudChat) return cloudHeader(empty: true);
    final compact = MediaQuery.sizeOf(context).height - _composerExtent < 500;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        compact ? 12 : 65,
        20,
        compact ? 20 : 65,
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: compact ? 28 : 35,
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
          SizedBox(height: compact ? 16 : 24),
          label(
            '你好，我是 ${demo.role.name}',
            size: 23,
            weight: FontWeight.w500,
            color: sceneInk,
          ),
          const SizedBox(height: 10),
          label(
            demo.activeConnection == null
                ? (demo.useBeta ? '先检查内测状态，继续你的对话。' : '登录中转站或使用自己的模型连接。')
                : '想聊点什么？我在这里。',
            size: 13,
            color: sceneMuted,
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
            if (!demo.useBeta) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).pushReplacementNamed('/settings/models'),
                icon: const Icon(Icons.hub_outlined, size: 18),
                label: const Text('连接自己的 API'),
              ),
            ],
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
  }

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

  void holdDisclosurePosition() {
    follow = false;
    _bottomSeek++;
    _messageSeek++;
    // Also stop a bottom-follow animation already in flight.
    if (scroll.hasClients) scroll.jumpTo(scroll.offset);
  }

  Widget executionRow(CloudTranscriptRow row) {
    final anchor = keys.putIfAbsent(row.first, () => GlobalKey());
    for (final message in row.messages) {
      keys[message] = anchor;
    }
    final assistant = cloudChats.engineFor(_conversation);
    final current = row.taskId != null
        ? row.taskId == assistant.taskId
        : identical(row.messages.last, demo.messages.last);
    final phase = current ? assistant.phase : null;
    final thinking = [
      for (final m in row.allMessages)
        if (m.thinking?.isNotEmpty == true) m.thinking!,
    ].join('\n\n');
    final question =
        demo.messages
            .where((m) => m.user && m.turnId == row.first.turnId)
            .lastOrNull
            ?.text ??
        '';
    final result = row.reply != null && (!current || !demo.streaming)
        ? TaskResult.fromMessages(row.messages, phase: phase, goal: question)
        : null;
    final linkedTask = result?.linkedTask(personalSpace);
    final artifactIds = row.messages
        .expand((m) => (m.toolExecution?.artifactIds ?? '').split(','))
        .where((id) => id.startsWith('artifact_'))
        .toSet()
        .toList();
    final artifactBatches = row.messages
        .expand((m) => (m.toolExecution?.artifactBatches ?? '').split(','))
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final linkedPlan =
        taskPlans.records
            .where((p) => p.id == result?.managedPlanId)
            .firstOrNull ??
        (linkedTask == null
            ? null
            : taskPlans
                  .forTask(linkedTask.id)
                  .where((p) => p.state == 'enabled')
                  .firstOrNull);
    final linkedResource = taskPlans.resources
        .where((r) => r['id'] == result?.managedResourceId)
        .firstOrNull;
    final layout = appearance.text('assistantBubbleLayout');
    final speaker =
        demo.personas.where((p) => p.id == row.first.authorId).firstOrNull ??
        demo.role;
    return Padding(
      key: anchor,
      padding: EdgeInsets.only(bottom: demo.compact ? 14 : 24),
      child: AssistantReplyLayout(
        layout: layout,
        wide: appearance.flag('wideChat'),
        thinking: appearance.flag('showThinking') && thinking.isNotEmpty
            ? thinking
            : null,
        onThinkingToggle: holdDisclosurePosition,
        avatar: appearance.flag('avatars')
            ? messageAvatar(
                row.first,
                speaker,
                key: ValueKey('execution-avatar-${row.first.id}'),
              )
            : null,
        child: Column(
          crossAxisAlignment: layout == 'centered'
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: [
            CloudExecutionDisclosure(
              messages: row.messages,
              phase: phase,
              pendingRequestId: current
                  ? (assistant.pending?['requestId'] as String?)
                  : null,
              expanded: _expandedExecutionIds.contains(row.first.id),
              onToggle: () {
                // Reading a long process must not trigger the automatic bottom seek.
                holdDisclosurePosition();
                setState(() {
                  if (!_expandedExecutionIds.remove(row.first.id)) {
                    _expandedExecutionIds.add(row.first.id);
                  }
                });
              },
              onResume: phase == 'permission' || phase == 'confirmation'
                  ? demo.resumeCloud
                  : null,
              onCapabilities: phase == 'permission'
                  ? openCloudCapabilities
                  : null,
            ),
            if (row.reply != null) ...[
              const SizedBox(height: 12),
              message(
                row.reply!,
                row.replyIndex!,
                embedded: true,
                showThinking: false,
              ),
              if (current && assistant.canConfirmResult)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('task-confirm-result'),
                      onPressed: () =>
                          unawaited(cloudChats.confirmResult(_conversation)),
                      icon: const Icon(Icons.check_circle_outline, size: 17),
                      label: const Text('用户确认完成'),
                    ),
                  ),
                ),
            ],
            if (artifactIds.isNotEmpty || artifactBatches.isNotEmpty) ...[
              const SizedBox(height: 10),
              CloudFileCard(
                key: ValueKey('files-${row.first.id}'),
                ids: artifactIds,
                batches: artifactBatches,
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 10),
              TaskResultCard(
                key: ValueKey('task-result-${row.first.id}'),
                result: result.displayTask(
                  linkedTask,
                  plan: linkedPlan,
                  resource: linkedResource,
                ),
                opening: _openingResultIds.contains(row.first.id),
                saving: _savingTaskIds.contains(row.first.id),
                manageLabel: linkedTask == null ? '加入任务' : '查看任务',
                onManage: result.managedTaskId != null
                    ? null
                    : () async {
                        if (linkedTask != null) {
                          await editPersonalRecord(
                            context,
                            store: personalSpace,
                            record: linkedTask,
                          );
                          return;
                        }
                        if (!_savingTaskIds.add(row.first.id)) return;
                        setState(() {});
                        try {
                          await result.addToTasks(personalSpace);
                          if (mounted) toast(context, '已加入已完成任务');
                        } catch (_) {
                          if (mounted) toast(context, '保存任务未完成，请重试。');
                        } finally {
                          _savingTaskIds.remove(row.first.id);
                          if (mounted) setState(() {});
                        }
                      },
                onOpen: result.target == null && linkedTask == null
                    ? null
                    : () async {
                        if (!_openingResultIds.add(row.first.id)) return;
                        setState(() {});
                        try {
                          if (result.managedTaskId != null &&
                              linkedTask != null) {
                            await editPersonalRecord(
                              context,
                              store: personalSpace,
                              record: linkedTask,
                            );
                          } else if (result.target != null) {
                            await deviceEngine.openResult(result.target!);
                          }
                        } catch (_) {
                          if (mounted) toast(context, '暂时无法打开对应软件，请检查应用授权范围。');
                        } finally {
                          _openingResultIds.remove(row.first.id);
                          if (mounted) setState(() {});
                        }
                      },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget messageAvatar(Message m, Persona speaker, {Key? key}) => Tooltip(
    key: key ?? ValueKey('message-avatar-${m.id}'),
    message: m.user ? '编辑我的角色卡' : '编辑对话角色卡',
    child: InkWell(
      onTap: () {
        if (m.user) {
          editUserCard(context);
        } else {
          demo.persona = demo.personas.indexOf(speaker);
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
                persona: speaker,
                square: appearance.flag('squareAvatars'),
              ),
      ),
    ),
  );

  Widget message(
    Message m,
    int i, {
    bool embedded = false,
    bool showThinking = true,
  }) {
    final speaker = m.authorId == null
        ? demo.role
        : demo.personas.where((p) => p.id == m.authorId).firstOrNull ??
              demo.role;
    final layout = appearance.text('assistantBubbleLayout');
    final fill = !m.user && layout != 'centered';
    final hasThinking =
        showThinking &&
        appearance.flag('showThinking') &&
        m.thinking?.isNotEmpty == true;
    keys.putIfAbsent(m, () => GlobalKey());
    final avatar = messageAvatar(m, speaker);
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
        if (m.quotes.isNotEmpty) _quoteBadge(m.quotes),
        bubble,
        if (m.pluginCards.isNotEmpty) CompanionMessageCards(message: m),
        if (m.contextNotice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              m.contextNotice!,
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ),
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
                label('我', size: 10, color: sceneMuted),
              if (appearance.flag('showTime'))
                label(
                  '${m.created.hour.toString().padLeft(2, '0')}:${m.created.minute.toString().padLeft(2, '0')}',
                  size: 10,
                  color: sceneMuted,
                ),
            ],
          ),
        if (!m.user)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 4),
              if (appearance.flag('showRole'))
                label(speaker.name, size: 10, color: sceneMuted),
              if (m.bookmarked) ...[
                const SizedBox(width: 6),
                Icon(Icons.bookmark, size: 12, color: green),
              ],
              PopupMenuButton<String>(
                tooltip: '消息菜单 ${i + 1}',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 17,
                icon: Icon(Icons.more_horiz, color: sceneMuted),
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
                  } else if (v == 'quote') {
                    demo.quoteMessage(_conversation, m);
                    focus.requestFocus();
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
    if (embedded) {
      return Padding(
        key: keys[m],
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: fill
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.start,
          children: [
            if (hasThinking)
              ThinkingDisclosure(
                text: m.thinking!,
                onToggle: holdDisclosurePosition,
                color: appearance.textColorEnabled('thinkingText')
                    ? appearance.textColor('thinkingText')
                    : sceneMuted,
              ),
            content,
          ],
        ),
      );
    }
    return Padding(
      key: keys[m],
      padding: EdgeInsets.only(bottom: demo.compact ? 14 : 24),
      child: !m.user
          ? AssistantReplyLayout(
              layout: layout,
              wide: appearance.flag('wideChat'),
              avatar: appearance.flag('avatars') ? avatar : null,
              thinking: hasThinking ? m.thinking : null,
              onThinkingToggle: holdDisclosurePosition,
              thinkingColor: appearance.textColorEnabled('thinkingText')
                  ? appearance.textColor('thinkingText')
                  : sceneMuted,
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
