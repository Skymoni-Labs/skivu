import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/character_avatar.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

void main() {
  testWidgets(
    'role avatar is resized, backed up, restored and excluded from prompts',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 900, 450),
        Paint()..color = Colors.teal,
      );
      final picture = recorder.endRecording();
      final avatar = (await tester.runAsync(() async {
        final image = await picture.toImage(900, 450);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        final avatar = await normalizeCharacterAvatar(bytes);
        final codec = await ui.instantiateImageCodec(avatar);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 256);
        expect(frame.image.height, 128);
        frame.image.dispose();
        codec.dispose();
        image.dispose();
        picture.dispose();
        return avatar;
      }))!;
      final disk = MemoryChats();
      final store = DemoStore(settings: TestModels(), storage: disk);
      await store.restore();
      store.role.avatar = avatar;
      final prompt = store.role.compiledPrompt;
      await store.saveChats();
      final restored = DemoStore(settings: TestModels(), storage: disk);
      await restored.restore();
      expect(restored.role.avatar, avatar);
      expect(restored.role.compiledPrompt, prompt);
      await tester.pumpWidget(
        MaterialApp(home: CharacterAvatar(persona: restored.role)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await restored.importChats(store.exportChats());
      expect(restored.role.avatar, avatar);
      await tester.pumpWidget(
        MaterialApp(
          home: CharacterAvatar(persona: restored.role, showDefault: true),
        ),
      );
      expect(find.byType(Image), findsNothing);
      final oldRole = restored.role.toJson()..remove('avatar');
      expect(Persona.fromJson(oldRole).avatar, isNull);
      expect(
        Persona.fromJson({...oldRole, 'avatar': 'invalid%'}).avatar,
        isNull,
      );
      store.dispose();
      restored.dispose();
    },
  );
}
