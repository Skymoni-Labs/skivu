// User-authorized original module migration; see MODULE-MIGRATION.md.
// ignore_for_file: file_names
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'voice_call_session.dart';
import 'voice_call_orb.dart';
import 'appearance.dart';

/// A full-screen route above the existing chat, keeping its composer and history.
class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({
    super.key,
    required this.session,
    required this.roleName,
    this.permissionBuilder,
    this.onHangUp,
    this.hasPermissions,
  });
  final VoidCallback? onHangUp;
  final VoiceCallSession session;
  final String roleName;
  final WidgetBuilder? permissionBuilder;
  final bool Function()? hasPermissions;
  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with WidgetsBindingObserver {
  VoiceCallSession get session => widget.session;
  final _captions = ScrollController();
  bool _subtitles = true, _following = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_changed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(session.start());
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_following) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _following && _captions.hasClients) {
          _captions.jumpTo(_captions.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A permission prompt may temporarily be inactive. Only leaving the app
    // pauses capture; resumption always requires an explicit microphone tap.
    if (state == AppLifecycleState.paused) unawaited(session.setMuted(true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    session.removeListener(_changed);
    session.dispose();
    _captions.dispose();
    super.dispose();
  }

  void _hangUp() {
    unawaited(session.end());
    if (widget.onHangUp != null) {
      widget.onHangUp!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _interrupt() {
    if ([
      VoiceCallPhase.thinking,
      VoiceCallPhase.speaking,
      VoiceCallPhase.transcribing,
    ].contains(session.phase)) {
      unawaited(session.interrupt());
    }
  }

  String get _status => switch (session.phase) {
    VoiceCallPhase.preparing => '正在连接角色语音…',
    VoiceCallPhase.listening => '你可以开始说话',
    VoiceCallPhase.userSpeaking => '我在听',
    VoiceCallPhase.transcribing => '正在听清你的话…',
    VoiceCallPhase.thinking => '正在想怎么回答你…',
    VoiceCallPhase.speaking =>
      session.previewing ? '正在试听角色声音 · 轻点光球可停止' : '轻点光球，打断并继续说',
    VoiceCallPhase.muted => '麦克风已关闭',
    VoiceCallPhase.error => session.needsPermission ? '开启麦克风后开始通话' : '通话已暂停',
    VoiceCallPhase.ended => '通话已结束',
  };

  Future<void> _showMore() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(widget.roleName),
              subtitle: Text(session.backend.speechDescription),
            ),
            if (session.backend.hasLocalVoice)
              SwitchListTile(
                title: const Text('本次通话使用本地模型声音'),
                subtitle: const Text('离线声音 0，不修改角色配置'),
                value: session.backend.usesLocalVoice,
                onChanged: (selected) {
                  Navigator.pop(context);
                  unawaited(session.selectLocalVoice(selected));
                },
              ),
            const ListTile(
              leading: Icon(Icons.hearing_outlined),
              title: Text('自动断句，轮流说话'),
              subtitle: Text('播放回复时暂停收音；轻点光球可打断。'),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('完整通话记录'),
              onTap: () {
                Navigator.pop(context);
                _showTranscript();
              },
            ),
            ListTile(
              leading: const Icon(Icons.volume_up_outlined),
              title: const Text('试听当前角色声音'),
              subtitle: const Text('不发送聊天消息'),
              onTap: () {
                Navigator.pop(context);
                unawaited(session.previewVoice());
              },
            ),
            ListTile(
              leading: const Icon(Icons.keyboard_outlined),
              title: const Text('输入一句话'),
              onTap: () {
                Navigator.pop(context);
                _sendText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('复制通话状态'),
              subtitle: const Text('仅阶段与耗时，不含对话、录音或密钥'),
              onTap: () async {
                final report = session.diagnosticReport;
                Navigator.pop(context);
                await Clipboard.setData(ClipboardData(text: report));
                if (mounted) {
                  ScaffoldMessenger.of(
                    this.context,
                  ).showSnackBar(const SnackBar(content: Text('通话诊断已复制')));
                }
              },
            ),
            if (widget.permissionBuilder != null)
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('查看工具授权'),
                onTap: () {
                  Navigator.pop(context);
                  _showPermissions();
                },
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _showTranscript() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('通话记录 · 同步保留在原对话'),
              ),
              Expanded(
                child: session.transcript.isEmpty
                    ? const Center(child: Text('还没有通话内容'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: session.transcript.length,
                        itemBuilder: (context, index) {
                          final entry = session.transcript[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.speaker,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                                const SizedBox(height: 4),
                                SelectableText(entry.text),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showPermissions() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: session.backend,
          builder: (context, _) =>
              widget.permissionBuilder?.call(context) ??
              const Text('没有待处理的工具授权'),
        ),
      ),
    ),
  );

  Future<void> _sendText() async {
    if (!session.canSendText) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请等待当前回复结束，或点光球打断后再输入')));
      return;
    }
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('说给角色听'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '使用当前对话的角色与模型'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    // The dialog's closing animation still owns the controller for one frame.
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (mounted && text != null) unawaited(session.sendText(text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final elapsed = session.elapsed.elapsed.inSeconds;
    final time =
        '${(elapsed ~/ 60).toString().padLeft(2, '0')}:${(elapsed % 60).toString().padLeft(2, '0')}';
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(session.end());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: colors.surface,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [colors.surface, const Color(0xff252837), colors.surface]
                  : [
                      const Color(0xfff8dde7),
                      const Color(0xffeee7f6),
                      const Color(0xffe0f0fb),
                    ],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 610;
                return Column(
                  children: [
                    SizedBox(
                      height: compact ? 44 : 52,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              tooltip: '通话设置',
                              onPressed: _showMore,
                              icon: const Icon(Icons.more_horiz),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _subtitles = !_subtitles),
                              style: TextButton.styleFrom(
                                foregroundColor: colors.onSurface,
                              ),
                              child: Text(
                                '字',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: _subtitles
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          Text(
                            widget.roleName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${session.phase == VoiceCallPhase.error ? '已暂停' : '语音通话'} · $time',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: VoiceCallOrb(
                            level: session.level,
                            dark: dark,
                            reducedMotion:
                                appearance.flag('reduceMotion') ||
                                [
                                  VoiceCallPhase.error,
                                  VoiceCallPhase.ended,
                                  VoiceCallPhase.muted,
                                ].contains(session.phase),
                            onTap: _interrupt,
                          ),
                        ),
                      ),
                    ),
                    if (_subtitles)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface.withValues(
                              alpha: dark ? .45 : .66,
                            ),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: colors.surface.withValues(alpha: .75),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: SizedBox(
                              height: compact ? 54 : 64,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: session.transcript.isEmpty
                                        ? Center(
                                            child: Text(
                                              '你们说的话，会轻轻留在这里',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                          )
                                        : NotificationListener<
                                            UserScrollNotification
                                          >(
                                            onNotification: (notification) {
                                              if (notification.direction !=
                                                      ScrollDirection.idle &&
                                                  _following) {
                                                setState(
                                                  () => _following = false,
                                                );
                                              }
                                              return false;
                                            },
                                            child: SingleChildScrollView(
                                              controller: _captions,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  for (final entry
                                                      in session.transcript.skip(
                                                        session
                                                                    .transcript
                                                                    .length >
                                                                3
                                                            ? session
                                                                      .transcript
                                                                      .length -
                                                                  3
                                                            : 0,
                                                      ))
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 6,
                                                          ),
                                                      child: Text.rich(
                                                        TextSpan(
                                                          children: [
                                                            TextSpan(
                                                              text:
                                                                  '${entry.speaker}  ',
                                                              style: TextStyle(
                                                                color: colors
                                                                    .onSurfaceVariant,
                                                                fontSize: 11,
                                                              ),
                                                            ),
                                                            TextSpan(
                                                              text: entry.text,
                                                            ),
                                                          ],
                                                        ),
                                                        style: theme
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              height: 1.55,
                                                            ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                  ),
                                  if (!_following)
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: FilledButton.tonal(
                                        onPressed: () {
                                          _following = true;
                                          _changed();
                                        },
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        child: const Text('回到最新'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.hasPermissions != null)
                      ListenableBuilder(
                        listenable: session.backend,
                        builder: (context, _) => widget.hasPermissions!()
                            ? TextButton.icon(
                                onPressed: _showPermissions,
                                icon: const Icon(Icons.shield_outlined),
                                label: const Text('角色需要工具授权 · 点击处理'),
                              )
                            : const SizedBox.shrink(),
                      ),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: compact ? 8 : 14,
                      ),
                      child: session.phase == VoiceCallPhase.error
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  session.error ?? '连接暂时中断',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall,
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    session.start(
                                      requestPermission:
                                          session.needsPermission,
                                    ),
                                  ),
                                  child: Text(
                                    session.needsPermission
                                        ? '允许麦克风并开始'
                                        : '重试连接',
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              _status,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        18,
                        4,
                        18,
                        compact ? 10 : 20,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _control(
                            session.muted
                                ? Icons.mic_off_outlined
                                : Icons.mic_none_rounded,
                            session.muted ? '开启麦克风' : '关闭麦克风',
                            () {
                              if (session.needsPermission) {
                                unawaited(
                                  session.start(requestPermission: true),
                                );
                              } else {
                                unawaited(session.setMuted(!session.muted));
                              }
                            },
                            compact: compact,
                            selected: session.muted,
                          ),
                          _control(
                            Icons.screen_share_outlined,
                            '共享屏幕，即将开放',
                            null,
                            compact: compact,
                          ),
                          _control(
                            Icons.videocam_outlined,
                            '视频，即将开放',
                            null,
                            compact: compact,
                          ),
                          _control(
                            Icons.close_rounded,
                            '挂断',
                            _hangUp,
                            compact: compact,
                            destructive: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _control(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    required bool compact,
    bool destructive = false,
    bool selected = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IconButton.filledTonal(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: Size.square(compact ? 56 : 66),
        backgroundColor: selected
            ? colors.primaryContainer
            : colors.onSurface.withValues(alpha: .055),
        disabledBackgroundColor: colors.onSurface.withValues(alpha: .025),
        foregroundColor: destructive
            ? const Color(0xffef515e)
            : colors.onSurface,
        disabledForegroundColor: colors.onSurface.withValues(alpha: .23),
      ),
      icon: Icon(icon, size: destructive ? 34 : 27),
    );
  }
}
