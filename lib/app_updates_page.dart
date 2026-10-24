import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_updates.dart';
import 'brand.dart';

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
  const AppUpdatesPage({super.key, this.updates, this.onBack});
  final AppUpdates? updates;
  final VoidCallback? onBack;
  @override
  State<AppUpdatesPage> createState() => _AppUpdatesPageState();
}

class _AppUpdatesPageState extends State<AppUpdatesPage>
    with WidgetsBindingObserver {
  AppUpdates get update => widget.updates ?? appUpdates;
  bool _expanded = true;
  bool get _busy => update.checking || update.downloading || update.installing;
  String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    update.check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) update.check(silent: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    animation: update,
    builder: (context, _) {
      final version =
          update.release?.version ?? update.device?.version ?? appVersion;
      final top = MediaQuery.paddingOf(context).top;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: const Color(0xff0c0b18),
          body: Stack(
            fit: StackFit.expand,
            children: [
              const RepaintBoundary(child: CustomPaint(painter: _UpdateSky())),
              Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        SingleChildScrollView(
                          key: const ValueKey('update-scroll'),
                          padding: EdgeInsets.fromLTRB(20, top + 80, 20, 32),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _hero(version),
                                  const SizedBox(height: 28),
                                  _versionCard(version),
                                  const SizedBox(height: 16),
                                  _notesCard(),
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
                        _header(),
                      ],
                    ),
                  ),
                  _bottomAction(),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget _hero(String version) => Column(
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
    return _UpdateGlass(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.system_update_alt_rounded,
              color: _paper,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(release == null ? '当前版本' : '可用更新', style: _heading),
                const SizedBox(height: 7),
                Text(
                  'Skivu $version${release == null
                      ? update.device == null
                            ? ''
                            : ' · 构建 ${update.device!.versionCode}'
                      : ' · ${_mb(release.size)}'}',
                  style: const TextStyle(
                    color: _secondary,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                if (release != null && update.device != null)
                  Text(
                    '已安装 ${update.device!.version}',
                    style: const TextStyle(
                      color: _secondary,
                      fontSize: 12,
                      height: 1.8,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notesCard() {
    final release = update.release;
    final showBundled =
        release == null &&
        (update.device == null || update.device!.version == appVersion);
    return _UpdateGlass(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: _expanded,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 14, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        release == null ? '此版本更新说明' : '更新说明',
                        style: _heading,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: _secondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0x1fffffff)),
            Padding(
              padding: const EdgeInsets.all(20),
              child: release != null
                  ? Text(
                      release.notes.trim().isEmpty
                          ? '此版本暂未提供详细更新说明。'
                          : release.notes.trim(),
                      style: _body,
                    )
                  : showBundled
                  ? const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('焕新的更新体验', style: _heading),
                        SizedBox(height: 10),
                        Text('全屏渐变与通透玻璃，版本信息、更新说明和注意事项分区呈现。', style: _body),
                        SizedBox(height: 20),
                        Text('下载与安装，状态更清楚', style: _heading),
                        SizedBox(height: 10),
                        Text(
                          '底部操作随更新状态切换，查看下载进度、取消下载，或在校验完成后继续安装。',
                          style: _body,
                        ),
                      ],
                    )
                  : const Text('当前版本暂未提供详细更新说明。', style: _body),
            ),
          ],
        ],
      ),
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
                      onSelected: (value) {
                        if (value == 'check') {
                          update.check();
                        } else {
                          _details();
                        }
                      },
                      itemBuilder: (_) => [
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
                          child: Text('版本信息', style: TextStyle(color: _paper)),
                        ),
                      ],
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
  Widget _bottomAction() => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x000b0a14), Color(0xf00b0a14), Color(0xff0b0a14)],
        stops: [0, .35, 1],
      ),
    ),
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 28, 20, 16),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (update.error != null ||
                  !update.supported ||
                  (update.message != null && update.message != '当前已是最新版本'))
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
              if (update.downloading) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_mb(update.downloadedBytes)} / ${_mb(update.release!.size)}',
                        style: const TextStyle(color: _secondary, fontSize: 12),
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
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: update.progress.clamp(0, 1),
                    minHeight: 3,
                    color: const Color(0xff1689ff),
                    backgroundColor: Colors.white12,
                    semanticsLabel: '更新包下载进度',
                  ),
                ),
                const SizedBox(height: 14),
              ],
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: !_busy && update.supported
                        ? const [Color(0xff0674ec), Color(0xff26a2ff)]
                        : const [Color(0xff234776), Color(0xff355b8b)],
                  ),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: const Color(0x448ecbff)),
                ),
                child: FilledButton(
                  key: const ValueKey('update-primary-action'),
                  onPressed: !update.supported || _busy ? null : _act,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: const Color(0xffe1e8f4),
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
                  child: Text(_action, textAlign: TextAlign.center),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '由 skymoni.com 提供更新服务',
                textAlign: TextAlign.center,
                style: TextStyle(color: _secondary, fontSize: 10),
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

/// Static, code-drawn light fields avoid a continuously animated download page.
class _UpdateSky extends CustomPainter {
  const _UpdateSky();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff0c0b18),
    );
    void glow(Offset center, double radius, Color color) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(center, radius, [
            color,
            color.withValues(alpha: 0),
          ]),
      );
    }

    glow(
      Offset(size.width * .12, size.height * .42),
      size.height * .48,
      const Color(0xff5549b3),
    );
    glow(
      Offset(size.width * .98, size.height * .65),
      size.height * .32,
      const Color(0xff713e85),
    );
    final path = Path()
      ..moveTo(-size.width * .3, size.height * .7)
      ..cubicTo(
        size.width * .3,
        size.height * .38,
        size.width * .7,
        size.height * .81,
        size.width * 1.3,
        size.height * .48,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xbbc15c36)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.height * .09
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 46),
    );
    glow(
      Offset(size.width * .45, size.height),
      size.height * .32,
      const Color(0xcc080810),
    );
  }

  @override
  bool shouldRepaint(covariant _UpdateSky oldDelegate) => false;
}
