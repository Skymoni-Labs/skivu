import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'state.dart';

/// Only audited, compiled-in presenters are supported. This is not a script loader.
enum ChatUiMode { classic, wechat, qq }

extension ChatUiModeName on ChatUiMode {
  String get title => switch (this) {
    ChatUiMode.classic => 'Skivu 原版',
    ChatUiMode.wechat => '微信模式',
    ChatUiMode.qq => 'QQ 模式',
  };
}

class UiPluginSettings extends ChangeNotifier {
  static const storageKey = 'skivu.ui-presenter.v1';
  ChatUiMode mode = ChatUiMode.classic;
  bool conversationVisible = false;
  int tab = 0;
  int homeRevision = 0;
  String? error;
  Future<void> _writes = Future.value();
  int _pending = 0;
  bool get busy => _pending > 0;

  Future<void> restore() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        storageKey,
      );
      mode =
          ChatUiMode.values.where((v) => v.name == saved).firstOrNull ??
          ChatUiMode.classic;
    } catch (_) {
      error = '界面配置读取失败，已使用原版。聊天记录不受影响。';
    }
    notifyListeners();
  }

  Future<bool> apply(ChatUiMode value) => _saveMode(() => value);

  Future<bool> setEnabled(ChatUiMode plugin, bool enabled) {
    if (plugin == ChatUiMode.classic) return Future.value(false);
    return _saveMode(
      () => enabled
          ? plugin
          : mode == plugin
          ? ChatUiMode.classic
          : mode,
      refresh: false,
    );
  }

  Future<bool> _saveMode(
    ChatUiMode Function() choose, {
    bool refresh = true,
  }) async {
    bool saved = false;
    _pending++;
    notifyListeners();
    _writes = _writes.then((_) async {
      try {
        final value = choose();
        if (!refresh && value == mode) {
          error = null;
          saved = true;
          return;
        }
        if (!await (await SharedPreferences.getInstance()).setString(
          storageKey,
          value.name,
        ))
          throw StateError('not saved');
        mode = value;
        tab = 0;
        conversationVisible = false;
        homeRevision++;
        error = null;
        saved = true;
      } catch (_) {
        error = '界面未能保存，请重试。聊天记录不受影响。';
      } finally {
        _pending--;
        notifyListeners();
      }
    });
    await _writes;
    return saved;
  }

  void showConversation() {
    conversationVisible = true;
    notifyListeners();
  }

  void showHome([int value = 0]) {
    homeRevision++;
    tab = value;
    conversationVisible = false;
    notifyListeners();
  }
}

final uiPlugins = UiPluginSettings();

/// A live projection, never an archive. Both sidebar and presenters address
/// exactly the same Persona/Conversation instances through their stable IDs.
class SocialChatBinding {
  SocialChatBinding(this.store);
  final DemoStore store;
  List<Persona> get contacts => List.unmodifiable(store.personas);
  Conversation get selected => store.conversations[store.conversation];
  Persona? owner(Conversation chat) =>
      store.personas.where((p) => p.id == chat.personaId).firstOrNull;
  List<Conversation> forRole(String id) => store.conversationsFor(id);
  List<Conversation> get inbox {
    final values = store.visibleConversations
        .where((c) => owner(c) != null)
        .toList();
    values.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final ad = a.messages.lastOrNull?.created;
      final bd = b.messages.lastOrNull?.created;
      return (bd ?? DateTime(1970)).compareTo(ad ?? DateTime(1970));
    });
    return values;
  }

  bool activate(String id) {
    final index = store.conversations.indexWhere((c) => c.id == id);
    if (index < 0 || owner(store.conversations[index]) == null) return false;
    // Re-entering the same conversation must not cancel its pending response.
    if (store.conversation != index) store.selectChat(index);
    return true;
  }

  bool create(String roleId) {
    if (!store.personas.any((p) => p.id == roleId)) return false;
    store.newChat(personaId: roleId);
    return true;
  }
}
