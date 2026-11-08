import 'dart:convert';

/// Reads only a top-level final.message string. Tool JSON is never displayed.
String? assistantFinalPrefix(String source) {
  var text = source.trimLeft();
  if (text.startsWith('```')) {
    final newline = text.indexOf('\n');
    if (newline < 0) return null;
    text = text.substring(newline + 1).trimLeft();
  }
  if (!text.startsWith('{')) return null;
  var cursor = 1;
  String? type, message;
  final keys = <String>{};
  void whitespace() {
    while (cursor < text.length && RegExp(r'\s').hasMatch(text[cursor]))
      cursor++;
  }

  while (cursor < text.length) {
    whitespace();
    if (cursor >= text.length || text[cursor] == '}') break;
    final key = _string(text, cursor);
    if (key == null ||
        !key.$3 ||
        !keys.add(key.$1) ||
        !{'type', 'message'}.contains(key.$1))
      return null;
    cursor = key.$2;
    whitespace();
    if (cursor >= text.length || text[cursor++] != ':') return null;
    whitespace();
    final value = _string(text, cursor);
    if (value == null) return null;
    if (key.$1 == 'type') {
      if (!value.$3) return null;
      type = value.$1;
      if (type != 'final') return null;
    } else {
      message = value.$1;
    }
    cursor = value.$2;
    if (!value.$3) break;
    whitespace();
    if (cursor >= text.length || text[cursor] == '}') break;
    if (text[cursor++] != ',') return null;
  }
  return type == 'final' ? message : null;
}

(String, int, bool)? _string(String text, int start) {
  if (start >= text.length || text[start] != '"') return null;
  var cursor = start + 1, safe = cursor;
  while (cursor < text.length) {
    final char = text[cursor];
    if (char == '"') {
      try {
        return (
          jsonDecode(text.substring(start, cursor + 1)) as String,
          cursor + 1,
          true,
        );
      } catch (_) {
        return null;
      }
    }
    if (char == '\\') {
      if (cursor + 1 >= text.length) break;
      if (text[cursor + 1] == 'u') {
        if (cursor + 6 > text.length) break;
        cursor += 6;
      } else {
        cursor += 2;
      }
    } else {
      cursor++;
    }
    safe = cursor;
  }
  try {
    var value = jsonDecode('${text.substring(start, safe)}"') as String;
    if (value.isNotEmpty &&
        value.codeUnitAt(value.length - 1) >= 0xd800 &&
        value.codeUnitAt(value.length - 1) <= 0xdbff)
      value = value.substring(0, value.length - 1);
    return (value, text.length, false);
  } catch (_) {
    return null;
  }
}
