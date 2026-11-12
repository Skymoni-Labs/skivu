import 'dart:convert';

/// Accepts a complete action envelope. Text outside that envelope is never run.
Map<String, dynamic> parseAssistantAction(String raw) {
  var text = raw.trim();
  Map<String, dynamic> action;
  if (text.startsWith('```')) {
    if (text.length < 6 || !text.endsWith('```')) {
      throw const FormatException('动作代码围栏不完整。');
    }
    final start = text.startsWith('json', 3) ? 7 : 3;
    text = text.substring(start, text.length - 3).trim();
    action = _jsonAction(text);
  } else if (text.startsWith(_dsmlPrefix)) {
    action = _DsmlAction(text).read();
  } else {
    action = _jsonAction(text);
  }
  final call = action['type'] == 'call';
  final expected = call
      ? const {'type', 'tool', 'arguments', 'message'}
      : const {'type', 'message'};
  if (!const {'call', 'final'}.contains(action['type']) ||
      action.length != expected.length ||
      !action.keys.every(expected.contains) ||
      action['message'] is! String) {
    throw const FormatException('模型动作格式无效。');
  }
  if (call &&
      (action['tool'] is! String ||
          (action['tool'] as String).trim().isEmpty ||
          action['arguments'] is! Map<String, dynamic>)) {
    throw const FormatException('模型工具参数无效。');
  }
  return action;
}

Map<String, dynamic> _jsonAction(String text) {
  final json = _JsonStructure(text)..scanValue();
  json.skipWhitespace();
  if (json.offset != text.length) {
    throw const FormatException('动作之后包含额外内容。');
  }
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('模型动作必须是对象。');
  }
  return value;
}

const _dsmlPrefix = '<｜｜DSML｜｜ ';
const _parameterEnd = '</｜｜DSML｜｜ parameter>';

class _DsmlAction {
  _DsmlAction(this.text);
  final String text;
  int offset = 0;

  void literal(String value) {
    while (offset < text.length && _isWhitespace(text.codeUnitAt(offset))) {
      offset++;
    }
    if (!text.startsWith(value, offset)) {
      throw const FormatException('DSML 动作结构不完整或含额外内容。');
    }
    offset += value.length;
  }

  Map<String, dynamic> read() {
    literal('${_dsmlPrefix}calls>');
    literal('${_dsmlPrefix}invoke name="call">');
    final fields = <String, dynamic>{};
    final parameter = RegExp(
      r'<｜｜DSML｜｜ parameter name="(tool|arguments|message)" string="(true|false)">',
    );
    for (var index = 0; index < 3; index++) {
      while (offset < text.length && _isWhitespace(text.codeUnitAt(offset))) {
        offset++;
      }
      final header = parameter.matchAsPrefix(text, offset);
      if (header == null) {
        throw const FormatException('DSML 参数结构无效。');
      }
      final name = header.group(1)!;
      final string = header.group(2) == 'true';
      if (fields.containsKey(name) || string == (name == 'arguments')) {
        throw const FormatException('DSML 参数重复或类型无效。');
      }
      offset = header.end;
      if (name == 'arguments') {
        final json = _JsonStructure(text, offset)..scanValue();
        fields[name] = jsonDecode(text.substring(offset, json.offset));
        offset = json.offset;
      } else {
        final end = text.indexOf(_parameterEnd, offset);
        if (end < 0) throw const FormatException('DSML 参数未结束。');
        fields[name] = text.substring(offset, end);
        if (name == 'tool') fields[name] = (fields[name] as String).trim();
        offset = end;
      }
      literal(_parameterEnd);
    }
    literal('</｜｜DSML｜｜ invoke>');
    literal('</｜｜DSML｜｜ calls>');
    if (offset != text.length) {
      throw const FormatException('DSML 动作之后包含额外内容。');
    }
    return {'type': 'call', ...fields};
  }
}

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

/// Checks object key uniqueness and depth before the standard JSON decoder runs.
class _JsonStructure {
  _JsonStructure(this.text, [this.offset = 0]);
  final String text;
  int offset;

  void skipWhitespace() {
    while (offset < text.length && _isWhitespace(text.codeUnitAt(offset))) {
      offset++;
    }
  }

  void consume(String value) {
    skipWhitespace();
    if (!text.startsWith(value, offset)) {
      throw const FormatException('JSON 动作结构无效。');
    }
    offset += value.length;
  }

  bool take(String value) {
    skipWhitespace();
    if (!text.startsWith(value, offset)) return false;
    offset += value.length;
    return true;
  }

  String string() {
    skipWhitespace();
    final start = offset;
    consume('"');
    while (offset < text.length) {
      final code = text.codeUnitAt(offset++);
      if (code == 0x22) {
        return jsonDecode(text.substring(start, offset)) as String;
      }
      if (code == 0x5c) offset++;
    }
    throw const FormatException('JSON 字符串未结束。');
  }

  void scanValue([int depth = 0]) {
    if (depth > 128) throw const FormatException('JSON 动作嵌套过深。');
    skipWhitespace();
    if (offset == text.length) throw const FormatException('JSON 动作不完整。');
    switch (text.codeUnitAt(offset)) {
      case 0x7b:
        offset++;
        final keys = <String>{};
        if (take('}')) return;
        do {
          if (!keys.add(string())) {
            throw const FormatException('JSON 对象包含重复字段。');
          }
          consume(':');
          scanValue(depth + 1);
        } while (take(','));
        consume('}');
      case 0x5b:
        offset++;
        if (take(']')) return;
        do {
          scanValue(depth + 1);
        } while (take(','));
        consume(']');
      case 0x22:
        string();
      default:
        final start = offset;
        while (offset < text.length &&
            !_isWhitespace(text.codeUnitAt(offset)) &&
            !const {0x2c, 0x5d, 0x7d}.contains(text.codeUnitAt(offset))) {
          offset++;
        }
        if (offset == start) {
          throw const FormatException('JSON 动作值无效。');
        }
        jsonDecode(text.substring(start, offset));
    }
  }
}
