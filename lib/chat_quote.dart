/// A local reference plus a text snapshot. Quoting never replaces the draft.
class ChatQuote {
  const ChatQuote({
    required this.chatId,
    required this.messageId,
    required this.sender,
    required this.text,
  });
  final String chatId, messageId, sender, text;
  String get preview => text.replaceAll(RegExp(r'\s+'), ' ').trim();
  Map<String, dynamic> toJson() => {
    'chatId': chatId,
    'messageId': messageId,
    'sender': sender,
    'text': text,
  };
  static List<ChatQuote> parseList(Object? raw) {
    if (raw is! List) return [];
    final result = <ChatQuote>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map ||
          item['chatId'] is! String ||
          item['messageId'] is! String ||
          item['sender'] is! String ||
          item['text'] is! String)
        continue;
      final chat = item['chatId'] as String, id = item['messageId'] as String;
      if (chat.isEmpty ||
          id.isEmpty ||
          chat.length > 160 ||
          id.length > 160 ||
          !seen.add('$chat/$id'))
        continue;
      result.add(
        ChatQuote(
          chatId: chat,
          messageId: id,
          sender: item['sender'],
          text: item['text'],
        ),
      );
    }
    return result;
  }
}
