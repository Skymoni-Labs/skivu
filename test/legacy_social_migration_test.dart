import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/legacy_social_migration.dart';
import 'package:ski/social_activity.dart';
import 'package:ski/social_settings.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

String archive({Map<String, dynamic>? host}) => jsonEncode({
  'schema': LegacySocialMigration.schema,
  'source': 'file:///android_asset/flutter_assets/assets/social_ui/index.html',
  'platform': 'android',
  'capturedAt': '2026-10-24T00:00:00Z',
  'storage': {
    'skivu.host.social.v1': host == null ? null : jsonEncode(host),
    'skivu.social-demo.v2': '{"note":"prototype-only"}',
    'skivu.chat-modes.html.v1': null,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(DemoStore, SocialActivity, SocialSettings)> models(
    MemoryChats storage,
  ) async {
    final store = DemoStore(settings: TestModels(), storage: storage);
    await store.restore();
    final settings = SocialSettings();
    await settings.restore();
    final activity = SocialActivity(
      settings: settings,
      startSession: (_, _) =>
          throw StateError('Migration must not call a model'),
      roleIds: () => [],
    );
    await activity.restore();
    addTearDown(() {
      activity.dispose();
      settings.dispose();
      store.dispose();
    });
    return (store, activity, settings);
  }

  test(
    'imports profile without replacing current name, avatar or fields; preserves raw prototype',
    () async {
      final storage = MemoryChats();
      final (store, activity, _) = await models(storage);
      store.userCard.addAll({'称呼': 'Current name', '地区': 'Current city'});
      final raw = archive(
        host: {
          'profile': {
            'name': 'Old name',
            'avatar': 'old-avatar-is-not-imported',
            'account': 'local-alias',
            'bio': 'Old bio',
            'city': 'Old city',
            'status': 'Reading',
          },
        },
      );
      var captures = 0;
      final migration = LegacySocialMigration(
        store: store,
        activity: activity,
        supported: true,
        archiveReader: ({required capture}) async {
          if (capture) captures++;
          return raw;
        },
      );
      addTearDown(migration.dispose);
      expect(await migration.ensure(ChatUiMode.wechat), isTrue);
      expect(store.userCard, {
        '称呼': 'Current name',
        '地区': 'Current city',
        '社交账号': 'local-alias',
        '个性签名': 'Old bio',
        '个人状态': 'Reading',
      });
      expect(store.userAvatar, isNull);
      expect(jsonDecode(storage.data!)['userCard']['个性签名'], 'Old bio');
      expect(await migration.exportBackup(), raw);
      expect(await migration.ensure(ChatUiMode.qq), isTrue);
      expect(captures, 1);
    },
  );

  test(
    'classic startup defers legacy posts until one selected channel; retries never duplicate',
    () async {
      final (store, activity, _) = await models(MemoryChats());
      final raw = archive(
        host: {
          'posts': [
            {
              'id': 'local-17',
              'author': 'self',
              'text': 'Keep this post',
              'images': <String>[],
              'likes': ['self'],
              'comments': [
                {'name': 'friend', 'text': 'Keep this comment'},
              ],
            },
          ],
        },
      );
      final migration = LegacySocialMigration(
        store: store,
        activity: activity,
        supported: true,
        archiveReader: ({required capture}) async => raw,
      );
      addTearDown(migration.dispose);
      expect(await migration.ensure(ChatUiMode.classic), isFalse);
      expect(migration.status, LegacySocialStatus.awaitingMode);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          LegacySocialMigration.doneKey,
        ),
        isNull,
      );
      expect(await migration.ensure(ChatUiMode.qq), isTrue);
      expect(activity.feed('qq').single['id'], 'legacy-qq-local-17');
      expect(activity.feed('wx'), isEmpty);
      await (await SharedPreferences.getInstance()).remove(
        LegacySocialMigration.doneKey,
      );
      expect(await migration.ensure(ChatUiMode.qq), isTrue);
      expect(activity.feed('qq'), hasLength(1));
      expect(activity.feed('qq').single['comments'], hasLength(1));
    },
  );

  test(
    'failed profile write keeps done unset and can retry successfully',
    () async {
      final storage = MemoryChats();
      final (store, activity, _) = await models(storage);
      final migration = LegacySocialMigration(
        store: store,
        activity: activity,
        supported: true,
        archiveReader: ({required capture}) async => archive(
          host: {
            'profile': {'bio': 'Recoverable'},
          },
        ),
      );
      addTearDown(migration.dispose);
      storage.failing = true;
      expect(await migration.ensure(ChatUiMode.wechat), isFalse);
      expect(store.userCard.containsKey('个性签名'), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          LegacySocialMigration.doneKey,
        ),
        isNull,
      );
      storage.failing = false;
      expect(await migration.ensure(ChatUiMode.wechat), isTrue);
      expect(jsonDecode(storage.data!)['userCard']['个性签名'], 'Recoverable');
    },
  );

  test('capture failure does not complete migration and can retry', () async {
    final (store, activity, _) = await models(MemoryChats());
    var fail = true;
    final migration = LegacySocialMigration(
      store: store,
      activity: activity,
      supported: true,
      archiveReader: ({required capture}) async {
        if (fail) throw StateError('temporary capture error');
        return archive();
      },
    );
    addTearDown(migration.dispose);
    expect(await migration.ensure(ChatUiMode.wechat), isFalse);
    expect(migration.status, LegacySocialStatus.failed);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        LegacySocialMigration.doneKey,
      ),
      isNull,
    );
    fail = false;
    expect(await migration.ensure(ChatUiMode.wechat), isTrue);
  });

  test(
    'unsupported platforms never capture or write a fake completion',
    () async {
      final (store, activity, _) = await models(MemoryChats());
      final migration = LegacySocialMigration(
        store: store,
        activity: activity,
        supported: false,
        archiveReader: ({required capture}) => throw StateError('must not run'),
      );
      addTearDown(migration.dispose);
      expect(await migration.ensure(ChatUiMode.qq), isFalse);
      expect(migration.status, LegacySocialStatus.unsupported);
      expect(await migration.readBackup(), isNull);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          LegacySocialMigration.doneKey,
        ),
        isNull,
      );
    },
  );

  test(
    'archive rejects other origins, unexpected keys and parsed instead of raw storage',
    () {
      final raw = jsonDecode(archive()) as Map<String, dynamic>;
      raw['source'] = 'https://example.invalid';
      expect(
        () => LegacySocialMigration.decodeArchive(jsonEncode(raw)),
        throwsFormatException,
      );
      raw['source'] =
          'file:///android_asset/flutter_assets/assets/social_ui/index.html';
      (raw['storage'] as Map)['skivu.host.social.v1'] = <String, dynamic>{};
      expect(
        () => LegacySocialMigration.decodeArchive(jsonEncode(raw)),
        throwsFormatException,
      );
      (raw['storage'] as Map)['skivu.host.social.v1'] = null;
      (raw['storage'] as Map)['unexpected'] = null;
      expect(
        () => LegacySocialMigration.decodeArchive(jsonEncode(raw)),
        throwsFormatException,
      );
    },
  );
}
