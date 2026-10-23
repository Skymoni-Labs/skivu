import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_interaction.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats;

Map<String, dynamic> event(String id) => {
  'id': id,
  'kind': 'file',
  'created': DateTime(2026, 10, 24).toIso8601String(),
  'user': true,
  'payload': {
    'name': 'note.txt',
    'data':
        'data:text/plain;base64,${base64Encode(utf8.encode('local fixture'))}',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'attachments remain in their original conversation across export and restart',
    () async {
      final disk = MemoryChats(), store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat();
      final binding = UiHostBinding(store), first = binding.selected;
      final command = {
        'protocol': 1,
        'command': 'chatInteraction',
        'chatId': first.id,
        'event': event('fixture-file-001'),
      };
      expect(binding.mutate(command), isNull);
      expect(binding.mutate(command), isNull);
      expect(first.interactions, hasLength(1));
      expect(first.messages, isEmpty);
      store.newChat();
      final second = binding.selected;
      expect(binding.mutate(command), contains('切换'));
      expect(second.interactions, isEmpty);
      disk.data = store.exportChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      expect(
        restored.conversations
            .firstWhere((c) => c.id == first.id)
            .interactions
            .single['payload']['name'],
        'note.txt',
      );
      expect(
        binding.snapshot(ChatUiMode.qq, force: true)['interactions'],
        isEmpty,
      );
      store.dispose();
      restored.dispose();
    },
  );
  test('invalid and executable presentation payloads are rejected', () {
    for (final data in [
      'https://example.com/file',
      'data:image/svg+xml;base64,PHN2Zz4=',
      'data:text/html;base64,PGh0bWw+',
    ]) {
      final e = event('fixture-file-002');
      e['payload'] = {'name': 'unsafe', 'data': data};
      expect(cleanChatInteraction(e), isNull);
    }
    final big = event('fixture-file-003');
    big['payload'] = {
      'name': 'large.txt',
      'data':
          'data:text/plain;base64,${base64Encode(List.filled(2 * 1024 * 1024 + 1, 0))}',
    };
    expect(cleanChatInteraction(big), isNull);
  });
  test(
    'clear and undo include attachments without losing new events',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat();
      final binding = UiHostBinding(store), chat = binding.selected;
      binding.mutate({
        'protocol': 1,
        'command': 'chatInteraction',
        'chatId': chat.id,
        'event': event('fixture-file-004'),
      });
      final backup = store.clearChatMessages(chat.id)!;
      expect(chat.interactions, isEmpty);
      expect(chat.interactionsClearedAt, isNotNull);
      binding.mutate({
        'protocol': 1,
        'command': 'chatInteraction',
        'chatId': chat.id,
        'event': event('fixture-file-005'),
      });
      expect(store.restoreClearedMessages(backup), isTrue);
      expect(chat.interactions.map((e) => e['id']), [
        'fixture-file-004',
        'fixture-file-005',
      ]);
      expect(chat.interactionsClearedAt, isNull);
      store.dispose();
    },
  );
}
