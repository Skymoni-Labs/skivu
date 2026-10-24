import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/native_social_portrait.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';

void main() {
  final role = Persona(
    '角色',
    '',
    '',
    '',
    const Color(0xff7295a9),
    Icons.auto_awesome,
  );
  late Map<String, dynamic> original;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = appearance.values;
    appearance.set('squareAvatars', false);
  });
  tearDown(() {
    for (final e in original.entries) appearance.set(e.key, e.value);
  });
  Widget host(Widget child) => MaterialApp(home: Center(child: child));
  BorderRadius radius(WidgetTester tester) =>
      tester.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius
          as BorderRadius;

  testWidgets(
    'hosted role has exactly one color1f layer and fixed 25dp glyph independent of interface text',
    (tester) async {
      appearance.set('interfaceTextEnabled', true);
      appearance.set('interfaceText', 0xffff0000);
      await tester.pumpWidget(
        host(NativeSocialPortrait(mode: ChatUiMode.wechat, persona: role)),
      );
      final box = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(NativeSocialPortrait),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(box.color, const Color(0x1f7295a9));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, role.icon);
      expect(icon.size, 25);
      expect(icon.color, const Color(0xff24332e));
      expect(radius(tester), BorderRadius.circular(5));
      expect(
        tester.getSize(find.byType(NativeSocialPortrait)),
        const Size(38, 38),
      );
    },
  );

  testWidgets(
    'mode big and contextual radius match hosted portraits while square option wins every override',
    (tester) async {
      await tester.pumpWidget(
        host(
          NativeSocialPortrait(mode: ChatUiMode.qq, persona: role, size: 64),
        ),
      );
      expect(radius(tester), BorderRadius.circular(32));
      await tester.pumpWidget(
        host(
          NativeSocialPortrait(
            mode: ChatUiMode.wechat,
            persona: role,
            size: 64,
            large: true,
          ),
        ),
      );
      expect(radius(tester), BorderRadius.circular(7));
      expect(tester.widget<Icon>(find.byType(Icon)).size, 43);
      await tester.pumpWidget(
        host(
          NativeSocialPortrait(
            mode: ChatUiMode.qq,
            persona: role,
            size: 64,
            borderRadius: 7,
          ),
        ),
      );
      expect(radius(tester), BorderRadius.circular(7));
      appearance.set('squareAvatars', true);
      await tester.pumpWidget(
        host(
          NativeSocialPortrait(
            mode: ChatUiMode.qq,
            persona: role,
            size: 64,
            square: false,
            borderRadius: 7,
          ),
        ),
      );
      expect(radius(tester), BorderRadius.zero);
    },
  );

  testWidgets(
    'self fallback paints original SVG background hair face shirt and collar colours',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        host(
          RepaintBoundary(
            key: key,
            child: const NativeSocialPortrait(
              mode: ChatUiMode.wechat,
              user: true,
              size: 48,
              square: true,
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      int colour(int x, int y) {
        final i = (y * 48 + x) * 4;
        return (pixels!.getUint8(i + 3) << 24) |
            (pixels.getUint8(i) << 16) |
            (pixels.getUint8(i + 1) << 8) |
            pixels.getUint8(i + 2);
      }

      expect(colour(6, 26), 0xffb2c8c6);
      expect(colour(24, 5), 0xff4d6e6a);
      expect(colour(24, 24), 0xfff4dfca);
      expect(colour(24, 44), 0xff749b9b);
      expect(colour(24, 37), 0xfff3dfd0);
      expect(find.byType(Icon), findsNothing);
    },
  );

  testWidgets(
    'real avatar bytes take precedence unchanged and invalid pictures fall back safely',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP2kAAAAASUVORK5CYII=',
      );
      role.avatar = bytes;
      addTearDown(() => role.avatar = null);
      await tester.pumpWidget(
        host(NativeSocialPortrait(mode: ChatUiMode.qq, persona: role)),
      );
      expect(
        (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes,
        same(bytes),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Icon), findsNothing);
      expect(radius(tester), BorderRadius.circular(19));
      await tester.pumpWidget(
        host(
          NativeSocialPortrait(
            mode: ChatUiMode.wechat,
            persona: role,
            bytes: base64Decode('AQID'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Icon>(find.byType(Icon)).icon, role.icon);
      expect(tester.takeException(), isNull);
    },
  );
}
