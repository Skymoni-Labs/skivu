import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/character_avatar.dart';
import 'package:ski/native_social_portrait.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'wallpaper_test.dart' show imageBytes;

void main() {
  testWidgets('existing and new cloud roles use the supplied default artwork', (
    tester,
  ) async {
    final role = Persona.fromJson(createCloudPersona().toJson());
    expect(role.avatar, isNull);
    final before = role.toJson();
    await tester.pumpWidget(MaterialApp(home: CharacterAvatar(persona: role)));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultCloudRoleAvatar), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(role.toJson(), before);
    role.avatar = imageBytes;
    await tester.pumpWidget(MaterialApp(home: CharacterAvatar(persona: role)));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultCloudRoleAvatar), findsNothing);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
    await tester.pumpWidget(
      MaterialApp(home: CharacterAvatar(persona: role, showDefault: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DefaultCloudRoleAvatar), findsOneWidget);
    expect(role.avatar, imageBytes);
  });

  testWidgets(
    'WeChat and QQ share the cloud default and preserve custom portraits',
    (tester) async {
      final role = createCloudPersona();
      for (final mode in [ChatUiMode.wechat, ChatUiMode.qq]) {
        role.avatar = null;
        await tester.pumpWidget(
          MaterialApp(
            home: NativeSocialPortrait(mode: mode, persona: role),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DefaultCloudRoleAvatar), findsOneWidget);
        role.avatar = imageBytes;
        await tester.pumpWidget(
          MaterialApp(
            home: NativeSocialPortrait(mode: mode, persona: role),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DefaultCloudRoleAvatar), findsNothing);
        expect(
          tester.widget<Image>(find.byType(Image)).image,
          isA<MemoryImage>(),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
