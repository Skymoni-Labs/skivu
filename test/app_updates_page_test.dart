import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/app_platform.dart';
import 'package:ski/app_updates.dart';
import 'package:ski/app_updates_page.dart';
import 'package:ski/brand.dart';

class _Platform extends AppPlatform {
  @override
  bool get supported => true;
}

class _Updates extends AppUpdates {
  _Updates() : super(platform: _Platform()) {
    device = const AppDeviceInfo(
      version: appVersion,
      versionCode: 29,
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
  version: '0.2.26',
  versionCode: 30,
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 24, bottom: 24),
        ),
        child: child!,
      ),
      home: AppUpdatesPage(updates: updates, onBack: onBack),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'latest release has its own header, collapsible notes and back action',
    (tester) async {
      final updates = _Updates();
      var backs = 0;
      await _open(tester, updates, onBack: () => backs++);
      expect(updates.checks, 1);
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.text('图片发送，一步直达'), findsOneWidget);
      await tester.tap(find.text('此版本更新说明'));
      await tester.pump();
      expect(find.text('图片发送，一步直达'), findsNothing);
      await tester.tap(find.text('此版本更新说明'));
      await tester.pump();
      expect(find.text('图片发送，一步直达'), findsOneWidget);
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
      expect(find.textContaining('当前版本：$appVersion (29)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
