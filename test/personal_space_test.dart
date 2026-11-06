import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/personal_space.dart';

void main() {
  test(
    'concurrent saves preserve both records and restart restores them',
    () async {
      String? data;
      final store = PersonalSpaceStore(
        read: () async => data,
        write: (s) async {
          data = s;
        },
      );
      await Future.wait([
        store.save(memory: false, title: '散步', date: '2026-11-07'),
        store.save(memory: true, title: '节奏', body: '喜欢慢慢来'),
      ]);
      final restored = PersonalSpaceStore(read: () async => data);
      await restored.restore();
      expect(restored.tasks.single.title, '散步');
      expect(restored.memories.single.body, '喜欢慢慢来');
    },
  );
  test('failed save preserves visible data and can be retried', () async {
    var fail = true;
    String? data;
    final store = PersonalSpaceStore(
      read: () async => data,
      write: (s) async {
        if (fail) throw StateError('disk');
        data = s;
      },
    );
    await expectLater(store.save(memory: false, title: '记录'), throwsStateError);
    expect(store.tasks, isEmpty);
    fail = false;
    await store.save(memory: false, title: '记录');
    expect(store.tasks.single.title, '记录');
  });
  test('bad storage is retained and cannot be overwritten', () async {
    const data = '{"version":999}';
    var writes = 0;
    final store = PersonalSpaceStore(
      read: () async => data,
      write: (_) async {
        writes++;
      },
    );
    await store.restore();
    expect(store.error, isNotNull);
    await expectLater(
      store.save(memory: false, title: '不能覆盖'),
      throwsStateError,
    );
    expect(writes, 0);
  });
  test(
    'completion, soft deletion and restore keep the original contents',
    () async {
      String? data;
      final store = PersonalSpaceStore(
        read: () async => data,
        write: (s) async {
          data = s;
        },
      );
      await store.save(memory: false, title: '散步', body: '留一点自由时间');
      final id = store.tasks.single.id;
      await store.toggle(id);
      await store.archive(id, memory: false);
      expect(store.tasks, isEmpty);
      await store.archive(id, memory: false, archived: false);
      expect(store.tasks.single.done, isTrue);
      expect(store.tasks.single.body, '留一点自由时间');
      expect((jsonDecode(data!) as Map)['tasks'], hasLength(1));
    },
  );
  test('invalid dates and empty memory never reach storage', () async {
    var writes = 0;
    final store = PersonalSpaceStore(
      read: () async => null,
      write: (_) async {
        writes++;
      },
    );
    await expectLater(
      store.save(memory: false, title: '日期', date: '2026-02-30'),
      throwsStateError,
    );
    await expectLater(
      store.save(memory: false, title: '时间', time: '25:00'),
      throwsStateError,
    );
    await expectLater(store.save(memory: true, title: '空白'), throwsStateError);
    expect(writes, 0);
  });
}
