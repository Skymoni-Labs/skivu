import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart';
import 'package:ski/appearance.dart';
import 'package:ski/personal_space.dart';
import 'package:ski/state.dart';
import 'package:ski/chat_backdrop.dart';
import 'preview_fixture.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    seedPreviewConversation();
    await personalSpace.restore();
  });
  testWidgets(
    'continuous scroll updates do not rebuild the composer every frame',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      demo.messages
        ..clear()
        ..addAll(
          List.generate(
            30,
            (i) => Message(false, '第 $i 段\n${'用于验证连续滚动时保留界面。\n' * 5}'),
          ),
        );
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer-field'));
      final before = tester.widget<TextField>(field);
      final gesture = await tester.startGesture(const Offset(180, 400));
      await gesture.moveBy(const Offset(0, -35));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<TextField>(field), same(before));
      for (var frame = 0; frame < 16; frame++) {
        await gesture.moveBy(const Offset(0, -6));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<TextField>(field), same(before));
      }
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native modules retain original conversation, role and unsent draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final conversation = demo.conversations[demo.conversation];
      final role = demo.role;
      final messages = List.of(demo.messages);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer-field'));
      await tester.enterText(field, '原来的未发送草稿');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      for (final index in [1, 2, 3, 4, 0]) {
        await tester.tap(find.byKey(ValueKey('main-module-$index')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(demo.conversations[demo.conversation], same(conversation));
        expect(demo.role, same(role));
      }
      expect(tester.widget<TextField>(field).controller!.text, '原来的未发送草稿');
      expect(demo.messages, orderedEquals(messages));
      expect(find.text('上下文角色：'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('five native module buttons fit a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      final rect = tester.getRect(find.byKey(ValueKey('main-module-$i')));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    final nav = tester.getSize(
      find.byKey(const ValueKey('main-module-dock-surface')),
    );
    expect(nav.height, 56); // Measure the visible Skymoni dock, not its anchor.
    final input = tester.getRect(
      find.byKey(const ValueKey('main-composer-input-surface')),
    );
    final dock = tester.getRect(
      find.byKey(const ValueKey('main-module-dock-surface')),
    );
    expect(dock.left, closeTo(input.left, .1));
    expect(dock.right, closeTo(input.right, .1));
    expect(dock.center.dx, closeTo(160, .1));
    final selection = tester.getRect(
      find.byKey(const ValueKey('main-module-moving-lens')),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('main-module-selection-body'))),
      selection,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'composer floats above a separate dock and other modules only retain the dock',
    (tester) async {
      final oldUsage = appearance.flag('showUsage');
      appearance.set('showUsage', false);
      addTearDown(() => appearance.set('showUsage', oldUsage));
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('main-composer-input-surface'));
      final dock = find.byKey(const ValueKey('main-module-dock-surface'));
      expect(
        tester.getRect(dock).top - tester.getRect(input).bottom,
        closeTo(8, .1),
      );
      for (final i in [1, 2, 3, 4]) {
        await tester.tap(find.byKey(ValueKey('main-module-$i')));
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        expect(dock, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('main-module-0')));
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'live glass keeps the transcript full height and allows scrolling beneath input',
    (tester) async {
      final old = appearance.flag('skymoniGlass');
      appearance.set('skymoniGlass', true);
      addTearDown(() => appearance.set('skymoniGlass', old));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      demo.messages
        ..clear()
        ..addAll(
          List.generate(
            30,
            (i) => Message(false, '第 $i 条\n${'可在玻璃背面滚动的内容。\n' * 8}'),
          ),
        );
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChatComposerBackdrop>(find.byType(ChatComposerBackdrop))
            .liveContent,
        isTrue,
      );
      final list = find.byType(ListView).first;
      final controller = tester.widget<ListView>(list).controller!;
      await tester.drag(list, const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('回到底部'));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent - 220);
      await tester.pumpAndSettle();
      final surface = tester.getRect(
        find.byKey(const ValueKey('main-composer-input-surface')),
      );
      final tail = tester.getRect(
        find.byKey(const ValueKey('message-bubble-29')),
      );
      expect(tail.bottom, greaterThan(surface.top + 40));
      expect(tester.getRect(list).bottom, greaterThanOrEqualTo(surface.bottom));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'quote menu creates a removable compact tag without replacing draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      demo.messages
        ..clear()
        ..addAll([Message(true, '一个问题'), Message(false, '一段需要引用的完整回答')]);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer-field'));
      await tester.enterText(field, '我的原草稿');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final menu = find.byTooltip('消息菜单 2');
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用到输入框'));
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '我的原草稿');
      final badge = find.byKey(const ValueKey('chat-draft-quote-badge'));
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge).width, lessThan(112));
      expect(tester.getSize(badge).height, lessThanOrEqualTo(28));
      final surface = tester.getRect(
        find.byKey(const ValueKey('main-composer-input-surface')),
      );
      for (final tooltip in ['对话设置', '添加内容', '发送消息']) {
        final rect = tester.getRect(find.byTooltip(tooltip).last);
        expect(surface.contains(rect.topLeft), isTrue);
        expect(
          surface.contains(rect.bottomRight - const Offset(.1, .1)),
          isTrue,
        );
      }
      await tester.tap(find.text('1 条引用'));
      await tester.pumpAndSettle();
      expect(find.text('引用内容 · 1'), findsOneWidget);
      expect(find.text('定位原文'), findsOneWidget);
      await tester.tap(find.byTooltip('移除此条引用'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('引用内容 · 0'))).pop();
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, '我的原草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'one glass lens slides continuously and rapid taps preserve draft',
    (tester) async {
      final previous = appearance.flag('reduceMotion');
      final oldPreference = demo.prefs['减少动态效果'];
      appearance.set('reduceMotion', false);
      demo.prefs['减少动态效果'] = false;
      addTearDown(() {
        appearance.set('reduceMotion', previous);
        demo.prefs['减少动态效果'] = oldPreference ?? false;
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer-field'));
      await tester.enterText(field, '动效切换时保留草稿');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final lens = find.byKey(const ValueKey('main-module-moving-lens'));
      final initial = tester.getCenter(lens).dx;
      await tester.tap(find.byKey(const ValueKey('main-module-4')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final moving = tester.getCenter(lens).dx;
      final target = tester
          .getCenter(find.byKey(const ValueKey('main-module-4')))
          .dx;
      expect(moving, greaterThan(initial));
      expect(moving, lessThan(target));
      expect(lens, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('main-module-1')));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.byKey(const ValueKey('main-module-3')));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(lens).dx,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('main-module-3'))).dx,
          .1,
        ),
      );
      expect(field, findsNothing);
      expect(demo.conversations[demo.conversation].draft, '动效切换时保留草稿');
      await tester.tap(find.byKey(const ValueKey('main-module-0')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '动效切换时保留草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reduced motion moves the selected lens immediately', (
    tester,
  ) async {
    final previous = appearance.flag('reduceMotion');
    appearance.set('reduceMotion', true);
    addTearDown(() => appearance.set('reduceMotion', previous));
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('main-module-3')));
    await tester.pump();
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('main-module-moving-lens')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('main-module-3'))).dx,
        .1,
      ),
    );
    expect(
      find.byKey(const ValueKey('main-composer-input-surface')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
