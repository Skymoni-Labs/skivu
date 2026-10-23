import 'preview_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:ski/appearance.dart';
import 'package:ski/appearance_profiles.dart';
import 'package:ski/appearance_settings.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/glass.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/main.dart';
import 'package:ski/wallpaper.dart';
import 'glass_preferences_test.dart' show MemoryGlassPreferences;
import 'wallpaper_test.dart' show MemoryPersistence;

class MemoryAppearance implements AppearancePersistence {
  Map<String, dynamic>? saved;
  Future<void> Function()? beforeWrite;
  @override
  Future<Map<String, dynamic>?> read() async => saved;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    await beforeWrite?.call();
    saved = Map.of(value);
  }
}

class MemoryProfiles implements ProfilePersistence {
  Map<String, dynamic>? data;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> read() async => data;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('Full');
    data = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

void main() {
  test(
    'enabling a module color never activates dormant colors in other modules',
    () async {
      final disk = MemoryAppearance()
        ..saved = {
          'userText': 0xff7e22ce,
          'assistantText': 0xff9a3412,
          'customMessageColors': true,
        };
      final model = AppearancePreferences(persistence: disk);
      await model.restore();
      expect(model.textColor('userText'), const Color(0xff17212b));
      model.set('assistantText', 0xff1d4ed8);
      await model.save();
      final restarted = AppearancePreferences(persistence: disk);
      await restarted.restore();
      expect(restarted.textColor('assistantText'), const Color(0xff1d4ed8));
      for (final key in [
        'interfaceText',
        'inputText',
        'thinkingText',
        'userText',
      ]) {
        expect(restarted.textColor(key), const Color(0xff17212b));
        expect(restarted.textColorEnabled(key), isFalse);
      }
      await restarted.resetSection(['assistantTextEnabled', 'assistantText']);
      expect(restarted.textColor('userText'), const Color(0xff17212b));
      expect(restarted.flag('customMessageColors'), isTrue);
      model.dispose();
      restarted.dispose();
    },
  );

  test(
    'legacy palette and inherited custom fonts migrate without future links',
    () {
      final migrated = cleanAppearance({
        'customTextColors': true,
        'assistantText': 0xff9a3412,
        'inputText': 0xff166534,
        'font': 'custom',
        'fontAsset': 'font-123',
        'assistantFont': 'inherit',
        'userFont': 'serif',
      });
      for (final key in textAppearanceModules.keys) {
        expect(migrated['${key}Enabled'], isTrue);
      }
      expect(migrated['assistantFont'], 'custom');
      expect(migrated['assistantFontAsset'], 'font-123');
      expect(migrated['inputFontAsset'], 'font-123');
      expect(migrated['thinkingFontAsset'], 'font-123');
      expect(migrated['userFont'], 'serif');
      final changed = cleanAppearance({...migrated, 'fontAsset': 'font-456'});
      expect(changed['assistantFontAsset'], 'font-123');
      expect(changed['inputFontAsset'], 'font-123');
      expect(changed['assistantText'], 0xff9a3412);
      expect(changed['inputText'], 0xff166534);
    },
  );

  test(
    'each module font and color survives restart and a single-module reset',
    () async {
      final disk = MemoryAppearance();
      final model = AppearancePreferences(persistence: disk);
      model.set('font', 'serif');
      expect(model.fontFamily('assistantFont'), 'SkiSans');
      expect(model.fontFamily('inputFont'), 'SkiSans');
      model.set('assistantFont', 'mono');
      model.set('assistantText', 0xff9a3412);
      model.set('userText', 0xff1d4ed8);
      model.set('thinkingFont', 'serif');
      model.set('thinkingText', 0xff64748b);
      model.set('inputText', 0xff166534);
      model.set('interfaceText', 0xff7e22ce);
      await model.save();
      final restored = AppearancePreferences(persistence: disk);
      await restored.restore();
      expect(restored.fontFamily('assistantFont'), 'SkiMono');
      expect(restored.fontFamily('thinkingFont'), 'SkiSerif');
      expect(restored.fontFamily('inputFont'), 'SkiSans');
      expect(restored.textColor('assistantText'), const Color(0xff9a3412));
      restored.set('assistantTextEnabled', false);
      expect(restored.textColor('assistantText'), const Color(0xff17212b));
      expect(restored.textColor('userText'), const Color(0xff1d4ed8));
      await restored.resetSection([
        'assistantFont',
        'assistantFontAsset',
        'assistantText',
        'assistantTextEnabled',
      ]);
      expect(restored.fontFamily('assistantFont'), 'SkiSans');
      expect(restored.fontFamily(), 'SkiSerif');
      expect(restored.textColor('inputText'), const Color(0xff166534));
      expect(restored.textColor('thinkingText'), const Color(0xff64748b));
      expect(restored.textColor('interfaceText'), const Color(0xff7e22ce));
      model.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'text color picker validates, saves independently and previews color',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final disk = MemoryAppearance();
      final model = AppearancePreferences(persistence: disk);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AppearanceSettings(preferences: model),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final module = find.byKey(const ValueKey('appearance-module-userText'));
      await tester.ensureVisible(module);
      await tester.tap(
        find.descendant(of: module, matching: find.text('我的消息')),
      );
      await tester.pumpAndSettle();
      final setting = find.byKey(const ValueKey('appearance-color-userText'));
      await tester.ensureVisible(setting);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('color-hex-input'));
      await tester.enterText(field, '#xyz');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 6 位 RGB，例如 #347DA3'), findsOneWidget);
      final blue = find.widgetWithText(ActionChip, '靛蓝');
      await tester.ensureVisible(blue);
      await tester.tap(blue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(model.textColor('userText'), const Color(0xff1d4ed8));
      expect(model.textColorEnabled('userText'), isTrue);
      expect(model.textColorEnabled('assistantText'), isFalse);
      expect(model.textColorEnabled('interfaceText'), isFalse);
      expect(model.flag('customMessageColors'), isFalse);
      expect(
        tester.widget<Text>(find.text('今天想和你聊一会儿。')).style!.color,
        const Color(0xff1d4ed8),
      );
      expect(disk.saved!['userText'], 0xff1d4ed8);
      await tester.ensureVisible(setting);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      final white = find.widgetWithText(ActionChip, '白色');
      await tester.ensureVisible(white);
      await tester.tap(white);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.textColor('userText'), const Color(0xff1d4ed8));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reply width controls update the actual appearance preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = AppearancePreferences(persistence: MemoryAppearance());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AppearanceSettings(preferences: model),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-tab-2')));
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('preview-assistant-bubble'));
    final preview = find.byKey(const ValueKey('appearance-chat-preview'));
    final user = find.byWidgetPredicate(
      (w) => w is ChatBubbleSurface && w.user,
    );
    final originalUser = tester.getRect(user);
    final widths = <double>[];
    for (final mode in ['centered', 'side', 'full']) {
      final option = find.byKey(
        ValueKey('appearance-assistantBubbleLayout-$mode'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      widths.add(tester.getSize(bubble).width);
      expect(tester.getRect(user).left, originalUser.left);
      expect(tester.getSize(user).width, originalUser.width);
      expect(model.text('assistantBubbleLayout'), mode);
    }
    expect(widths[0], lessThan(widths[1]));
    expect(widths[1], lessThan(widths[2]));
    expect(tester.getTopLeft(bubble).dx - tester.getTopLeft(preview).dx, 16);
    final avatar = find.byKey(const ValueKey('preview-role-avatar'));
    expect(
      tester.getTopLeft(bubble).dy - tester.getBottomLeft(avatar).dy,
      greaterThanOrEqualTo(12),
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    expect(tester.takeException(), isNull);
  });

  setUp(seedPreviewConversation);
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'appearance migration, validation and partial reset preserve unrelated preferences',
    () async {
      final disk = MemoryAppearance()
        ..saved = {
          'mode': 'dark',
          'textScale': 9,
          'inputBlur': 24,
          'font': 'unknown',
          'userColor': 0x123456,
          'extra': 'ignored',
          'assistantBubbleLayout': 'invalid',
        };
      final model = AppearancePreferences(persistence: disk);
      await model.restore();
      expect(model.dark, isTrue);
      expect(model.number('textScale'), 1.4);
      expect(model.text('font'), 'sans');
      expect(model.text('assistantBubbleLayout'), 'centered');
      expect(model.color('userColor').toARGB32(), 0xff123456);
      model.set('inputBlur', double.nan);
      expect(model.number('inputBlur'), 24);
      model.set('inputStyle', 'compact');
      expect(model.flag('capsuleToolbar'), isTrue);
      model.set('capsuleToolbar', false);
      model.set('showTokens', true);
      model.set('userFont', 'serif');
      model.set('assistantBubbleLayout', 'full');
      await model.save();
      final restarted = AppearancePreferences(persistence: disk);
      await restarted.restore();
      expect(restarted.text('inputStyle'), 'compact');
      expect(restarted.flag('capsuleToolbar'), isFalse);
      expect(restarted.fontFamily('userFont'), 'SkiSerif');
      expect(restarted.flag('showTokens'), isTrue);
      expect(restarted.text('assistantBubbleLayout'), 'full');
      await restarted.resetSection(['font', 'textScale']);
      expect(restarted.number('textScale'), 1);
      expect(restarted.number('inputBlur'), 24);
      expect(restarted.text('inputStyle'), 'compact');
      model.dispose();
      restarted.dispose();
    },
  );
  test(
    'a delayed failed save cannot replace newer appearance settings',
    () async {
      final blocked = Completer<void>();
      var writes = 0;
      final disk = MemoryAppearance()
        ..beforeWrite = () async {
          if (writes++ == 0) {
            await blocked.future;
            throw StateError('Old failure');
          }
        };
      final model = AppearancePreferences(persistence: disk);
      model.set('inputBlur', 10);
      final first = model.save();
      model.set('inputBlur', 26);
      model.set('toolbarBlur', 8);
      final second = model.save();
      blocked.complete();
      await Future.wait([first, second]);
      expect(disk.saved!['inputBlur'], 26);
      expect(disk.saved!['toolbarBlur'], 8);
      expect(model.error, isNull);
      disk.beforeWrite = () async => throw StateError('Full');
      await model.save();
      expect(model.error, isNotNull);
      disk.beforeWrite = null;
      await model.save();
      expect(model.error, isNull);
      model.dispose();
    },
  );
  test(
    'named profiles restore full appearance and independent glass values and handle failed deletion',
    () async {
      final prefs = AppearancePreferences(persistence: MemoryAppearance());
      final glass = GlassPreferences(persistence: MemoryGlassPreferences());
      final wallpaper = WallpaperController(persistence: MemoryPersistence());
      final disk = MemoryProfiles();
      AppearanceProfiles manager() => AppearanceProfiles(
        persistence: disk,
        preferences: prefs,
        glass: glass,
        background: wallpaper,
      );
      final profiles = manager();
      prefs.set('font', 'serif');
      prefs.set('inputBlur', 22);
      prefs.set('showTime', true);
      glass.setBlur(leftSide: true, value: 4);
      glass.setBubbleBlur(user: false, value: 17);
      await profiles.create('我的阅读外观');
      expect(profiles.items, hasLength(1));
      final id = profiles.active!;
      final restarted = manager();
      await restarted.restore();
      prefs.set('font', 'sans');
      prefs.set('inputBlur', 2);
      glass.setBlur(leftSide: true, value: 12);
      glass.setBubbleBlur(user: false, value: 0);
      await restarted.apply(id);
      expect(restarted.error, isNull);
      expect(prefs.fontFamily(), 'SkiSerif');
      expect(prefs.number('inputBlur'), 22);
      expect(prefs.flag('showTime'), isTrue);
      expect(glass.leftBlur, 4);
      expect(glass.assistantBlur, 17);
      await restarted.rename('夜读');
      expect(restarted.items.single['name'], '夜读');
      disk.fail = true;
      await restarted.remove();
      expect(restarted.items, hasLength(1));
      expect(restarted.error, isNotNull);
      disk.fail = false;
      await restarted.remove();
      expect(restarted.items, isEmpty);
      expect(prefs.fontFamily(), 'SkiSerif');
      profiles.dispose();
      restarted.dispose();
      prefs.dispose();
      glass.dispose();
      wallpaper.dispose();
    },
  );
  testWidgets(
    'all appearance sections fit a narrow screen and input blur controls save',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final disk = MemoryAppearance();
      final model = AppearancePreferences(persistence: disk);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: AppearanceSettings(preferences: model),
                ),
              ),
            ),
          ),
        ),
      );
      for (final index in [0, 1, 2, 3, 4]) {
        final tab = find.byKey(ValueKey('appearance-tab-$index'));
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (index == 3) {
          final input = find.byKey(const ValueKey('appearance-inputBlur'));
          await tester.ensureVisible(input);
          await tester.drag(input, const Offset(300, 0));
          await tester.pumpAndSettle();
          expect(disk.saved!['inputBlur'], 30);
          expect(model.number('toolbarBlur'), 2);
        }
      }
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'real composer keeps draft, focus and selection while glass, fonts and scale change',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final before = appearance.values;
      addTearDown(() {
        for (final e in before.entries) {
          appearance.set(e.key, e.value);
        }
      });
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer-field'));
      await tester.enterText(field, '保留输入框里的草稿');
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );
      appearance.set('inputBlur', 24);
      appearance.set('toolbarBlur', 8);
      appearance.set('capsuleToolbar', false);
      appearance.set('font', 'serif');
      appearance.set('accent', 0xffa46487);
      appearance.set('uiScale', 1.2);
      appearance.set('textScale', 1.4);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.text, '保留输入框里的草稿');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      final chrome = tester.widgetList<ConfigurableGlassSurface>(
        find.byType(ConfigurableGlassSurface),
      );
      final surface = find.byWidget(
        chrome.firstWhere((w) => w.area == 'inputBlur'),
      );
      final lens = tester.widget<LiquidGlassLens>(
        find
            .descendant(of: surface, matching: find.byType(LiquidGlassLens))
            .first,
      );
      expect(lens.style.blur, 24);
      expect(
        find.byKey(const ValueKey('glass-rectangle-toolbar')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SkiGlassButton>(
              find.ancestor(
                of: find.byTooltip('打开工作区'),
                matching: find.byType(SkiGlassButton),
              ),
            )
            .plain,
        isTrue,
      );
      appearance.set('inputStyle', 'compact');
      appearance.set('floatingInput', false);
      appearance.set('avatars', false);
      appearance.set('showTokens', true);
      appearance.set('userFont', 'mono');
      await tester.pumpAndSettle();
      expect(controller.text, '保留输入框里的草稿');
      expect(tester.widget<TextField>(field).minLines, 1);
      expect(find.byIcon(Icons.person_rounded), findsNothing);
      expect(find.text('— tok'), findsWidgets);
      expect(
        tester
            .widgetList<ConfigurableGlassSurface>(
              find.byType(ConfigurableGlassSurface),
            )
            .firstWhere((w) => w.area == 'inputBlur')
            .radius,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );
}
