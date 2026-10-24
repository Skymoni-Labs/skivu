import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:ski/chat_storage.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/chat_storage_platform_io.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats;

String archive(int n) => jsonEncode({
  'schema': 'skivu-chats-v1',
  'conversations': [],
  'generation': n,
});

class SlowChats extends ChatStorage {
  final started = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  String? latest;
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {
    writes++;
    if (writes == 1) {
      started.complete();
      await release.future;
    }
    latest = value;
  }
}

class TransactionChats extends MemoryChats {
  final replacing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> replaceArchive(String value) async {
    replacing.complete();
    await release.future;
    await write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'clear purges legacy and managed recovery copies without touching unrelated files',
    () async {
      final dir = await Directory.systemTemp.createTemp('skivu-clear-test-');
      addTearDown(() => dir.delete(recursive: true));
      final seed = DemoStore(storage: MemoryChats());
      await seed.restore();
      seed.messages.add(Message(true, 'private old conversation'));
      SharedPreferences.setMockInitialValues({
        ChatStorage.key: seed.exportChats(),
      });
      final store = DemoStore(
        storage: ChatStorage(files: PlatformChatStorage(directory: dir)),
      );
      await store.restore();
      await File(
        '${dir.path}/archive.damaged.123.json',
      ).writeAsString(seed.exportChats());
      await File('${dir.path}/unrelated.json').writeAsString('leave me');
      await store.clearChats();
      expect(
        (await SharedPreferences.getInstance()).getString(ChatStorage.key),
        isNull,
      );
      expect(
        await File('${dir.path}/unrelated.json').readAsString(),
        'leave me',
      );
      expect(
        await File('${dir.path}/archive.damaged.123.json').exists(),
        isFalse,
      );
      await File('${dir.path}/archive.json').writeAsString('corrupt');
      final reopened = DemoStore(
        storage: ChatStorage(files: PlatformChatStorage(directory: dir)),
      );
      await reopened.restore();
      expect(reopened.storageError, isNull);
      expect(
        reopened.exportChats(),
        isNot(contains('private old conversation')),
      );
      await File('${dir.path}/archive.json').delete();
      await File('${dir.path}/archive.previous.json').delete();
      expect(
        await ChatStorage(files: PlatformChatStorage(directory: dir)).read(),
        isNull,
      );
      store.dispose();
      seed.dispose();
      reopened.dispose();
    },
  );
  test(
    'concurrent atomic writes serialize and recover after failed candidate',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'skivu-concurrent-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final files = PlatformChatStorage(directory: dir);
      final writes = <Future<void>>[];
      for (var i = 0; i < 30; i++) {
        writes.add(files.write(archive(i), recover: i == 12));
      }
      await Future.wait(writes);
      expect(await files.read(), archive(29));
      await expectLater(files.write('invalid'), throwsFormatException);
      await files.write(archive(30));
      expect(await files.read(), archive(30));
    },
  );
  test(
    'autosaves during replacement wait until imported memory is applied',
    () async {
      final disk = TransactionChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final imported = jsonDecode(store.exportChats()) as Map<String, dynamic>;
      (imported['conversations'] as List).first['draft'] = 'imported';
      final restoring = store.importChats(jsonEncode(imported));
      await disk.replacing.future;
      for (var i = 0; i < 100; i++) {
        store.saveChats();
      }
      disk.release.complete();
      await restoring;
      await store.saveChats();
      expect(disk.data, contains('imported'));
      expect(store.conversations[store.conversation].draft, 'imported');
      store.dispose();
    },
  );
  test(
    'semantic corruption falls back to fully validated previous and saves safely',
    () async {
      final dir = await Directory.systemTemp.createTemp('skivu-semantic-test-');
      addTearDown(() => dir.delete(recursive: true));
      final seed = DemoStore(storage: MemoryChats());
      await seed.restore();
      seed.messages.add(Message(true, 'verified previous'));
      final good = seed.exportChats();
      final bad = jsonDecode(good) as Map<String, dynamic>;
      bad['conversations'] = [
        {'id': 'bad', 'messages': 42},
      ];
      await File('${dir.path}/archive.previous.json').writeAsString(good);
      await File('${dir.path}/archive.json').writeAsString(jsonEncode(bad));
      final store = DemoStore(
        storage: ChatStorage(files: PlatformChatStorage(directory: dir)),
      );
      await store.restore();
      expect(store.storageError, isNull);
      expect(store.messages.single.text, 'verified previous');
      await store.saveChats();
      expect(
        (await dir.list().toList()).any(
          (f) => f.path.contains('archive.damaged.'),
        ),
        isTrue,
      );
      store.dispose();
      seed.dispose();
    },
  );
  test(
    'explicit import and clear recover two corrupt generations; autosave cannot',
    () async {
      for (final clear in [false, true]) {
        final dir = await Directory.systemTemp.createTemp(
          'skivu-explicit-test-',
        );
        addTearDown(() => dir.delete(recursive: true));
        await File('${dir.path}/archive.json').writeAsString('bad current');
        await File(
          '${dir.path}/archive.previous.json',
        ).writeAsString('bad previous');
        final storage = ChatStorage(files: PlatformChatStorage(directory: dir));
        final store = DemoStore(storage: storage);
        await store.restore();
        expect(store.storageError, isNotNull);
        await store.saveChats();
        expect(
          await File('${dir.path}/archive.json').readAsString(),
          'bad current',
        );
        if (clear) {
          await store.clearChats();
        } else {
          await store.importChats(store.exportChats());
        }
        expect(store.storageError, isNull);
        final reopened = DemoStore(
          storage: ChatStorage(files: PlatformChatStorage(directory: dir)),
        );
        await reopened.restore();
        expect(reopened.storageError, isNull);
        final files = await dir.list().toList();
        expect(files.any((f) => f.path.contains('replaced.current.')), !clear);
        expect(files.any((f) => f.path.contains('replaced.previous.')), !clear);
        store.dispose();
        reopened.dispose();
      }
    },
  );
  test(
    'legacy preference is retained after verified migration and files become authoritative',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'skivu-migration-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      SharedPreferences.setMockInitialValues({ChatStorage.key: archive(1)});
      final storage = ChatStorage(files: PlatformChatStorage(directory: dir));
      expect(await storage.read(), archive(1));
      expect(
        (await SharedPreferences.getInstance()).getString(ChatStorage.key),
        archive(1),
      );
      await storage.write(archive(2));
      expect(
        await ChatStorage(files: PlatformChatStorage(directory: dir)).read(),
        archive(2),
      );
      expect(
        (await SharedPreferences.getInstance()).getString(ChatStorage.key),
        archive(1),
      );
    },
  );
  test('slow IO coalesces 1000 saves and persists the newest draft', () async {
    final disk = SlowChats();
    final store = DemoStore(storage: disk);
    await store.restore();
    final saving = store.saveChats();
    await disk.started.future;
    for (var i = 0; i < 1000; i++) {
      store.conversations[store.conversation].draft = 'draft-$i';
      store.saveChats();
    }
    disk.release.complete();
    await saving;
    expect(disk.writes, 2);
    expect(disk.latest, contains('draft-999'));
    store.dispose();
  });
  test(
    'atomic generations recover interrupted rename and reject both damaged files',
    () async {
      final dir = await Directory.systemTemp.createTemp('skivu-storage-test-');
      addTearDown(() => dir.delete(recursive: true));
      final disk = PlatformChatStorage(directory: dir);
      expect(await disk.read(), isNull);
      await disk.write(archive(1));
      await disk.write(archive(2));
      await File('${dir.path}/archive.json').writeAsString('truncated');
      final restart = PlatformChatStorage(directory: dir);
      expect(await restart.read(), archive(1));
      await restart.write(archive(3));
      expect(await PlatformChatStorage(directory: dir).read(), archive(3));
      expect(
        await File('${dir.path}/archive.previous.json').readAsString(),
        archive(1),
      );
      await File('${dir.path}/archive.json').writeAsString('bad');
      await File('${dir.path}/archive.previous.json').writeAsString('bad too');
      await expectLater(
        PlatformChatStorage(directory: dir).read(),
        throwsFormatException,
      );
      await expectLater(disk.write(archive(4)), throwsFormatException);
      expect(await File('${dir.path}/archive.json').readAsString(), 'bad');
    },
  );
  test(
    'interrupted replacement recovers previous without reading pending',
    () async {
      final dir = await Directory.systemTemp.createTemp('skivu-storage-test-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/archive.previous.json').writeAsString(archive(1));
      await File('${dir.path}/archive.pending.json').writeAsString(archive(2));
      expect(await PlatformChatStorage(directory: dir).read(), archive(1));
    },
  );
  test(
    'failed import keeps live conversations and verified prior snapshot',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      store.messages.add(Message(true, 'keep me'));
      await store.saveChats();
      final before = store.exportChats();
      disk.failing = true;
      await expectLater(store.importChats(before), throwsStateError);
      expect(store.exportChats(), before);
      store.dispose();
    },
  );
}
