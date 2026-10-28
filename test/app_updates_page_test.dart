import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/app_platform.dart';
import 'package:ski/app_updates.dart';
import 'package:ski/app_updates_page.dart';
import 'package:ski/brand.dart';
import 'package:ski/appearance.dart';
import 'appearance_test.dart' show MemoryAppearance;

class _Platform extends AppPlatform {
  @override
  bool get supported => true;
}

class _Updates extends AppUpdates {
  _Updates() : super(platform: _Platform()) {
    device = const AppDeviceInfo(
      version: appVersion,
      versionCode: 34,
      installedBytes: 70517047,
      packageName: 'com.skyjjgw.independent.ski',
      sdk: 36,
      abis: ['arm64-v8a'],
      signerSha256: 'fixture',
    );
    message = '当前已是最新版本';
  }
  int checks = 0, downloads = 0, installs = 0;
  @override
  Future<void> check({bool silent = false}) async {
    checks++;
  }

  @override
  Future<void> download() async {
    downloads++;
    downloading = true;
    changed();
  }

  @override
  Future<void> install() async {
    installs++;
  }

  @override
  void cancelDownload() {
    downloading = false;
    message = '已取消下载';
    changed();
  }
}

AppRelease _release(String notes) => AppRelease(
  version: '0.3.0',
  versionCode: 99,
  minSdk: 24,
  abi: 'arm64-v8a',
  url: Uri.https('skymoni.com', '/fixture'),
  hash: 'a' * 64,
  size: 10485760,
  notes: notes,
  packageName: 'com.skyjjgw.independent.ski',
  signerSha256: 'fixture',
);

Future<void> _open(
  WidgetTester tester,
  _Updates updates, {
  Size size = const Size(390, 844),
  double scale = 1,
  VoidCallback? onBack,
  bool settle = true,
  bool reduceMotion = false,
  AppearancePreferences? preferences,
}) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
          padding: const EdgeInsets.only(top: 24, bottom: 24),
        ),
        child: child!,
      ),
      home: AppUpdatesPage(
        updates: updates,
        onBack: onBack,
        preferences: preferences,
      ),
    ),
  );
  if (settle)
    await tester.pumpAndSettle();
  else
    await tester.pump();
}

void main() {
  testWidgets('meteor menu saves off across a preferences restart', (
    tester,
  ) async {
    final disk = MemoryAppearance();
    final preferences = AppearancePreferences(persistence: disk);
    addTearDown(preferences.dispose);
    await _open(tester, _Updates(), preferences: preferences);
    await tester.tap(find.byTooltip('更多更新选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('流星动效'));
    await tester.pumpAndSettle();
    expect(preferences.flag('updateMeteors'), isFalse);
    expect(disk.saved?['updateMeteors'], isFalse);
    final restored = AppearancePreferences(persistence: disk);
    await restored.restore();
    expect(restored.flag('updateMeteors'), isFalse);
    restored.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'latest release has its own header, collapsible notes and back action',
    (tester) async {
      final updates = _Updates();
      var backs = 0;
      await _open(tester, updates, onBack: () => backs++);
      expect(updates.checks, 1);
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.text('星空下的新版本'), findsOneWidget);
      expect(
        find.textContaining('Skivu $appVersion (34)  |  67.3 MB'),
        findsOneWidget,
      );
      final card = find.byKey(const ValueKey('update-version-card'));
      final openHeight = tester.getSize(card).height;
      await tester.tap(find.text('更新说明'));
      await tester.pump();
      expect(find.text('星空下的新版本'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      final midHeight = tester.getSize(card).height;
      expect(midHeight, lessThan(openHeight));
      await tester.pumpAndSettle();
      expect(tester.getSize(card).height, lessThan(midHeight));
      expect(find.text('星空下的新版本'), findsNothing);
      expect(find.byKey(const ValueKey('update-version-size')), findsOneWidget);
      await tester.tap(find.text('更新说明'));
      await tester.pumpAndSettle();
      expect(find.text('星空下的新版本'), findsOneWidget);
      await tester.tap(find.byTooltip('返回设置'));
      expect(backs, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large-text page keeps long notes scrollable above the fixed action',
    (tester) async {
      final updates = _Updates()
        ..release = _release(List.filled(50, '改进聊天与角色体验。').join('\n'));
      await _open(tester, updates, size: const Size(320, 640), scale: 1.5);
      final action = find.byKey(const ValueKey('update-primary-action'));
      final before = tester.getRect(action);
      expect(
        tester.getRect(find.byKey(const ValueKey('update-scroll'))).bottom,
        640,
      );
      expect(find.byKey(const ValueKey('update-starry-sky')), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 25; i++) {
        await tester.drag(
          find.byKey(const ValueKey('update-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
      }
      final tail = find.text('每一次更新，让陪伴更进一步。');
      expect(tester.getRect(tail).bottom, lessThan(tester.getRect(action).top));
      expect(tester.getRect(action), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download progress, cancellation and verified install use the existing actions',
    (tester) async {
      final updates = _Updates()..release = _release('改善体验');
      await _open(tester, updates);
      final primary = find.byKey(const ValueKey('update-primary-action'));
      await tester.tap(primary);
      await tester.pump();
      expect(updates.downloads, 1);
      expect(updates.installs, 0);
      updates.downloadedBytes = 5242880;
      updates.changed();
      await tester.pump();
      expect(find.text('正在下载 50%'), findsOneWidget);
      expect(tester.widget<FilledButton>(primary).onPressed, isNull);
      await tester.tap(find.text('取消下载'));
      await tester.pump();
      expect(find.text('已取消下载'), findsOneWidget);
      updates.downloadedPath = '/fixture/verified.apk';
      updates.message = '下载已校验，可继续安装';
      updates.changed();
      await tester.pump();
      expect(find.text('安装更新'), findsOneWidget);
      await tester.tap(primary);
      expect(updates.installs, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed check can retry and version information stays accessible',
    (tester) async {
      final updates = _Updates()
        ..error = '无法检查更新，请检查网络后重试。'
        ..message = null;
      await _open(tester, updates);
      expect(find.text('暂时无法获取更新信息'), findsOneWidget);
      await tester.tap(find.text('重新检查更新'));
      expect(updates.checks, 2);
      await tester.tap(find.byTooltip('更多更新选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('版本信息'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前版本：$appVersion (34)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'checking resolves by moving the hero and revealing the card smoothly',
    (tester) async {
      final updates = _Updates()..checking = true;
      await _open(tester, updates, settle: false);
      expect(
        find.byKey(const ValueKey('update-checking-capsule')),
        findsOneWidget,
      );
      final hero = find.byKey(const ValueKey('update-hero-space'));
      final initialHeight = tester.getSize(hero).height;
      final initialMarkTop = tester.getTopLeft(find.byType(BrandMark)).dy;
      expect(initialMarkTop, greaterThan(180));
      updates.checking = false;
      updates.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      final middleHeight = tester.getSize(hero).height;
      final middleMarkTop = tester.getTopLeft(find.byType(BrandMark)).dy;
      expect(middleMarkTop, lessThan(initialMarkTop));
      expect(middleHeight, lessThan(initialHeight));
      expect(middleHeight, greaterThan(250));
      await tester.pumpAndSettle();
      expect(tester.getSize(hero).height, 250);
      expect(
        tester.getTopLeft(find.byType(BrandMark)).dy,
        lessThan(middleMarkTop),
      );
      expect(
        tester.getTopLeft(find.byType(BrandMark)).dy,
        greaterThan(tester.getBottomLeft(find.byTooltip('返回设置')).dy),
      );
      expect(
        find.byKey(const ValueKey('update-checking-capsule')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('update-primary-action')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion preserves the same content and controls without a transition',
    (tester) async {
      final updates = _Updates();
      await _open(tester, updates, reduceMotion: true);
      await tester.tap(find.text('更新说明'));
      await tester.pump();
      expect(find.text('星空下的新版本'), findsNothing);
      expect(find.textContaining('67.3 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

// Flow timing is tested without a network request or fake waiting period.
