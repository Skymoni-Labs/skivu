import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_updates.dart';
import 'brand.dart';
import 'appearance.dart';
import 'update_sky.dart';

const _paper = Color(0xfff7f5ff);
const _secondary = Color(0xffc2bfd4);
const _heading = TextStyle(
  color: _paper,
  fontSize: 17,
  fontWeight: FontWeight.w600,
  height: 1.5,
);
const _body = TextStyle(color: _secondary, fontSize: 14, height: 1.85);

/// A dedicated update destination with its own safe areas, scroll and actions.
class AppUpdatesPage extends StatefulWidget {
  const AppUpdatesPage({
    super.key,
    this.updates,
    this.onBack,
    this.preferences,
  });
  final AppUpdates? updates;
  final VoidCallback? onBack;
  final AppearancePreferences? preferences;
  @override
  State<AppUpdatesPage> createState() => _AppUpdatesPageState();
}

class _AppUpdatesPageState extends State<AppUpdatesPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  AppUpdates get update => widget.updates ?? appUpdates;
  AppearancePreferences get _look => widget.preferences ?? appearance;
  bool _expanded = true, _resolved = false, _measureQueued = false;
  late final AnimationController _flow, _notes;
  late final Animation<double> _flowCurve, _notesCurve;
  final _actionKey = GlobalKey();
  double _actionExtent = 160;
  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) || _look.flag('reduceMotion');
  void _updated() {
    if (!mounted) return;
    if (!update.checking && !_resolved) {
      _resolved = true;
      if (_reduceMotion) {
        _flow.value = 1;
      } else {
        _flow.forward();
      }
    }
    _measureAction();
  }

  void _measureAction() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (!mounted) return;
      final box = _actionKey.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (box.size.height - _actionExtent).abs() > .5) {
        setState(() => _actionExtent = box.size.height);
      }
    });
  }

  void _toggleNotes() {
    setState(() => _expanded = !_expanded);
    if (_reduceMotion) {
      _notes.value = _expanded ? 1 : 0;
    } else if (_expanded) {
      _notes.forward();
    } else {
      _notes.reverse();
    }
  }

  bool get _busy => update.checking || update.downloading || update.installing;
  String _mb(int bytes) => bytes >= 1073741824
      ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
      : '${(bytes / 1048576).toStringAsFixed(1)} MB';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _notes = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 400),
    );
    _flowCurve = CurvedAnimation(parent: _flow, curve: Curves.easeOutCubic);
    _notesCurve = CurvedAnimation(parent: _notes, curve: Curves.easeInOutCubic);
    update.addListener(_updated);
    update.check();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updated());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) update.check(silent: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    update.removeListener(_updated);
    _flow.dispose();
    _notes.dispose();
    super.dispose();
  }

  String get _action {
    if (!update.supported) return '请在 Android App 中更新';
    if (update.installing) return '正在打开安装程序…';
    if (update.downloading)
      return '正在下载 ${(update.progress.clamp(0, 1) * 100).round()}%';
    if (update.checking) return '正在检查更新…';
    if (update.downloadedPath != null) return '安装更新';
    if (update.release != null) return '下载更新 · ${_mb(update.release!.size)}';
    return update.error == null ? '检查更新' : '重新检查更新';
  }

  Future<void> _act() async {
    if (update.downloadedPath != null) {
      await update.install();
    } else if (update.release != null) {
      await update.download();
    } else {
      await update.check();
    }
  }

  void _details() {
    final device = update.device;
    final release = update.release;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff292638),
        titleTextStyle: _heading,
        contentTextStyle: _body,
        title: const Text('版本信息'),
        content: SingleChildScrollView(
          child: SelectableText(
            [
              '当前版本：${device?.version ?? appVersion}${device == null ? '' : ' (${device.versionCode})'}',
              if (device != null) '应用：${device.packageName}',
              if (release != null) ...[
                '可用版本：${release.version} (${release.versionCode})',
                '安装包：${_mb(release.size)}',
                'SHA-256：${release.hash}',
              ],
              '更新服务：skymoni.com',
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: _paper),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([update, _flow, _look]),
    builder: (context, _) {
      final version =
          update.release?.version ?? update.device?.version ?? appVersion;
      final top = MediaQuery.paddingOf(context).top;
      _measureAction();
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: const Color(0xff060b1b),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final heroHeight = ui.lerpDouble(
                math.max(280, constraints.maxHeight * .68),
                250,
                _flowCurve.value,
              )!;
              return Stack(
                fit: StackFit.expand,
                children: [
                  UpdateSky(
                    key: const ValueKey('update-starry-sky'),
                    meteorsEnabled:
                        _look.flag('updateMeteors') && !_reduceMotion,
                  ),
                  SingleChildScrollView(
                    key: const ValueKey('update-scroll'),
                    physics: _resolved
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      20,
                      top + 80,
                      20,
                      _actionExtent + 28,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              key: const ValueKey('update-hero-space'),
                              height: heroHeight,
                              child: Center(
                                child: Transform.scale(
                                  scale: ui.lerpDouble(
                                    1.12,
                                    1,
                                    _flowCurve.value,
                                  )!,
                                  child: _hero(version),
                                ),
                              ),
                            ),
                            FadeTransition(
                              opacity: _flowCurve,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, .08),
                                  end: Offset.zero,
                                ).animate(_flowCurve),
                                child: IgnorePointer(
                                  ignoring: !_resolved,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _versionCard(version),
                                      const SizedBox(height: 30),
                                      const Text('注意事项', style: _heading),
                                      const SizedBox(height: 18),
                                      for (final (index, text) in const [
                                        '覆盖升级会保留本机聊天、角色和外观设置。建议更新前在“设置 → 聊天记录”导出备份。',
                                        '请保持网络畅通，并预留足够的存储空间。下载中断后，可返回此页重新下载。',
                                        '更新包会经过完整性与签名校验。系统要求时，请允许 Skivu 安装更新，并在安卓页面确认安装。',
                                      ].indexed)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 18,
                                          ),
                                          child: Text(
                                            '${index + 1}. $text',
                                            style: _body,
                                          ),
                                        ),
                                      const SizedBox(height: 4),
                                      const Text(
                                        '每一次更新，让陪伴更进一步。',
                                        style: TextStyle(
                                          color: _secondary,
                                          fontSize: 12,
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
                    ),
                  ),
                  _header(),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: SizedBox(
                        height: _actionExtent + 48,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x00060b1b),
                                Color(0x8a060b1b),
                                Color(0xd9060b1b),
                              ],
                              stops: [0, .6, 1],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: NotificationListener<SizeChangedLayoutNotification>(
                      onNotification: (_) {
                        _measureAction();
                        return true;
                      },
                      child: SizeChangedLayoutNotifier(
                        child: SizedBox(
                          key: _actionKey,
                          child: _bottomAction(),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
  Widget _hero(String version) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 8),
      const BrandMark(size: 42),
      const SizedBox(height: 14),
      const Text(
        'Skivu',
        style: TextStyle(
          color: _paper,
          fontSize: 18,
          letterSpacing: 3,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(height: 2),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          version,
          style: const TextStyle(
            color: _paper,
            fontSize: 64,
            height: 1.3,
            letterSpacing: -2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        update.checking
            ? '正在为你检查新版本'
            : update.release != null
            ? '新版本，已准备就绪'
            : update.error != null
            ? '暂时无法获取更新信息'
            : update.message == '当前已是最新版本'
            ? '已是最新版本'
            : '让每次对话，都有回应',
        textAlign: TextAlign.center,
        style: const TextStyle(color: _secondary, fontSize: 13),
      ),
    ],
  );
  Widget _versionCard(String version) {
    final release = update.release;
    final bytes = release?.size ?? update.device?.installedBytes;
    final build = release?.versionCode ?? update.device?.versionCode;
    return _UpdateGlass(
      key: const ValueKey('update-version-card'),
      padding: EdgeInsets.zero,
      radius: 28,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('软件版本', style: _heading),
                const SizedBox(height: 8),
                Text(
                  'Skivu $version${build == null ? '' : ' ($build)'}  |  ${bytes == null ? '大小暂不可用' : _mb(bytes)}',
                  key: const ValueKey('update-version-size'),
                  style: const TextStyle(
                    color: _secondary,
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
                if (release != null && update.device != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '已安装 ${update.device!.version}',
                      style: const TextStyle(color: _secondary, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Divider(height: 1, color: Color(0x24ffffff)),
          ),
          Semantics(
            expanded: _expanded,
            child: InkWell(
              onTap: _toggleNotes,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 18, 16),
                child: Row(
                  children: [
                    const Expanded(child: Text('更新说明', style: _heading)),
                    AnimatedRotation(
                      turns: _expanded ? .5 : 0,
                      duration: _reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 400),
                      curve: Curves.easeInOutCubic,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0x12ffffff),
                        ),
                        child: const Icon(
                          Icons.expand_more_rounded,
                          color: _paper,
                          size: 26,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _notes,
            builder: (context, _) => SizeTransition(
              sizeFactor: _notesCurve,
              axisAlignment: -1,
              child: FadeTransition(
                opacity: _notesCurve,
                child: Offstage(
                  offstage: _notes.isDismissed,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    child: _notesBody(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notesBody() {
    final release = update.release;
    if (release != null)
      return Text(
        release.notes.trim().isEmpty ? '此版本暂未提供详细更新说明。' : release.notes.trim(),
        style: _body,
      );
    if (update.device != null && update.device!.version != appVersion)
      return const Text('当前版本暂未提供详细更新说明。', style: _body);
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('星空下的新版本', style: _heading),
        SizedBox(height: 10),
        Text('软件版本与真实安装包大小集中展示，星空背景陪你查看本次更新。', style: _body),
        SizedBox(height: 20),
        Text('更自然的更新流程', style: _heading),
        SizedBox(height: 10),
        Text(
          '检测完成后，版本信息平滑收拢，更新卡片与悬浮按钮依次出现。说明展开与收起都有过渡，长内容可完整滚动查看。',
          style: _body,
        ),
      ],
    );
  }

  Widget _header() => Align(
    alignment: Alignment.topCenter,
    child: ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xff0c0b18), Color(0xe00c0b18), Color(0x000c0b18)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  _UpdateGlass(
                    padding: EdgeInsets.zero,
                    radius: 24,
                    child: IconButton(
                      tooltip: '返回设置',
                      onPressed:
                          widget.onBack ?? () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded, color: _paper),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      '软件更新',
                      style: TextStyle(
                        color: _paper,
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _UpdateGlass(
                    padding: EdgeInsets.zero,
                    radius: 24,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        listTileTheme: const ListTileThemeData(
                          iconColor: _paper,
                        ),
                      ),
                      child: PopupMenuButton<String>(
                        tooltip: '更多更新选项',
                        icon: const Icon(Icons.more_vert, color: _paper),
                        color: const Color(0xff292638),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        onSelected: (value) async {
                          if (value == 'check') {
                            update.check();
                          } else if (value == 'meteors') {
                            _look.set(
                              'updateMeteors',
                              !_look.flag('updateMeteors'),
                            );
                            await _look.save();
                            if (mounted && _look.error != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_look.error!)),
                              );
                            }
                          } else {
                            _details();
                          }
                        },
                        itemBuilder: (_) => [
                          CheckedPopupMenuItem(
                            value: 'meteors',
                            checked: _look.flag('updateMeteors'),
                            child: const Text(
                              '流星动效',
                              style: TextStyle(color: _paper),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'check',
                            enabled: update.supported && !_busy,
                            child: Text(
                              '重新检查更新',
                              style: TextStyle(
                                color: _busy ? _secondary : _paper,
                              ),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'details',
                            child: Text(
                              '版本信息',
                              style: TextStyle(color: _paper),
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
        ),
      ),
    ),
  );
  Widget _bottomAction() => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(28, 12, 28, 16),
    child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: AnimatedSwitcher(
          duration: _reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .2),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: !_resolved
              ? _UpdateGlass(
                  key: const ValueKey('update-checking-capsule'),
                  radius: 28,
                  child: const Row(
                    children: [
                      Expanded(child: Text('正在检测更新', style: _heading)),
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _paper,
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  key: const ValueKey('update-ready-actions'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (update.error != null ||
                        !update.supported ||
                        (update.message != null &&
                            update.message != '当前已是最新版本'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          !update.supported
                              ? '请在 Android 客户端中检查和安装更新。'
                              : update.error ?? update.message!,
                          key: const ValueKey('update-status'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: update.error == null
                                ? _secondary
                                : const Color(0xffffc6b6),
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    if (update.downloading)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_mb(update.downloadedBytes)} / ${_mb(update.release!.size)}',
                              style: const TextStyle(
                                color: _secondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: update.cancelDownload,
                            style: TextButton.styleFrom(
                              foregroundColor: _paper,
                              minimumSize: const Size(48, 44),
                            ),
                            child: const Text('取消下载'),
                          ),
                        ],
                      ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: !_busy && update.supported
                                ? const [Color(0xff0674ec), Color(0xff26a2ff)]
                                : const [Color(0xff234776), Color(0xff355b8b)],
                          ),
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: const Color(0x668ecbff)),
                        ),
                        child: Stack(
                          children: [
                            if (update.downloading)
                              Positioned.fill(
                                child: TweenAnimationBuilder<double>(
                                  key: const ValueKey('update-download-fill'),
                                  tween: Tween(
                                    end: update.progress.clamp(0, 1),
                                  ),
                                  duration: _reduceMotion
                                      ? Duration.zero
                                      : const Duration(milliseconds: 220),
                                  curve: Curves.easeOut,
                                  builder: (context, value, _) =>
                                      FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: value,
                                        child: const ColoredBox(
                                          color: Color(0x32ffffff),
                                        ),
                                      ),
                                ),
                              ),
                            FilledButton(
                              key: const ValueKey('update-primary-action'),
                              onPressed: !update.supported || _busy
                                  ? null
                                  : _act,
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                disabledBackgroundColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                disabledForegroundColor: const Color(
                                  0xffe1e8f4,
                                ),
                                minimumSize: const Size(double.infinity, 54),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 15,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: AnimatedSwitcher(
                                duration: _reduceMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 180),
                                child: Text(
                                  _action,
                                  key: ValueKey(
                                    update.downloading
                                        ? 'downloading'
                                        : update.checking
                                        ? 'checking'
                                        : update.installing
                                        ? 'installing'
                                        : update.downloadedPath != null
                                        ? 'install'
                                        : 'available',
                                  ),
                                  textAlign: TextAlign.center,
                                ),
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
    ),
  );
}

class _UpdateGlass extends StatelessWidget {
  const _UpdateGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 24,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99302c42),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: const Color(0x30ffffff)),
        ),
        child: Material(
          color: Colors.transparent,
          child: Padding(padding: padding, child: child),
        ),
      ),
    ),
  );
}
