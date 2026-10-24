import 'dart:convert';

/// Request-only pruning. Saved messages are never mutated.
class ContextBudgetResult {
  ContextBudgetResult(this.history, this.body, this.notice);
  final List<Map<String, String>> history;
  final String body;
  final String? notice;
}

class ContextBudgetException implements Exception {
  const ContextBudgetException();
}

ContextBudgetResult budgetContext({
  required List<Map<String, String>> history,
  required String system,
  required int? contextLimit,
  required int outputTokens,
  required bool account,
  required Map<String, dynamic> Function(List<Map<String, String>>) serialize,
}) {
  final values = history.map((m) => Map<String, String>.from(m)).toList();
  // Consecutive user messages are one pending turn, including queued media.
  var protected = values.length;
  for (var i = values.length - 1; i >= 0; i--) {
    if (values[i]['role'] == 'user') {
      protected = i;
      while (protected > 0 && values[protected - 1]['role'] == 'user') {
        protected--;
      }
      break;
    }
  }
  var removed = 0, images = 0;
  String encode() => jsonEncode(serialize(values));
  // Conservative text estimate: UTF-8 bytes upper-bound common tokenizers;
  // images reserve 4096 input tokens because provider image accounting varies.
  bool fits(String body) {
    final estimate =
        utf8.encode(system).length +
        16 +
        values.fold<int>(
          0,
          (n, m) =>
              n +
              utf8.encode(m['content'] ?? '').length +
              16 +
              (m.containsKey('image') ? 4096 : 0),
        );
    return (contextLimit == null || estimate + outputTokens <= contextLimit) &&
        (!account ||
            (values.length + (system.trim().isEmpty ? 0 : 1) <= 128 &&
                utf8.encode(body).length <= 262144));
  }

  var body = encode();
  // Only older media may be omitted, with an explicit model-visible marker.
  for (var i = 0; !fits(body) && i < protected; i++) {
    if (values[i].remove('image') != null) {
      values[i]['content'] =
          '${values[i]['content'] ?? ''}\n[历史图片未重发；需要查看时请用户重新提供]';
      images++;
      body = encode();
    }
  }
  while (!fits(body) && protected > 0) {
    var end = 1;
    while (end < protected && values[end]['role'] != 'user') {
      end++;
    }
    // Keep consecutive user media together until the assistant boundary.
    if (values.first['role'] == 'user') {
      end = 1;
      while (end < protected && values[end]['role'] == 'user') {
        end++;
      }
      while (end < protected && values[end]['role'] != 'user') {
        end++;
      }
    }
    values.removeRange(0, end);
    protected -= end;
    removed += end;
    body = encode();
  }
  if (!fits(body)) throw const ContextBudgetException();
  return ContextBudgetResult(
    values,
    body,
    removed == 0 && images == 0
        ? null
        : '本次仅发送最近完整对话（省略$removed条较早消息、$images张历史图片）；本地记录完整保留。',
  );
}
