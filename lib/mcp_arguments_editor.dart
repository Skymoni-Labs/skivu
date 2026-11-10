import 'dart:convert';
import 'package:flutter/material.dart';

bool supportsMcpForm(Map<String, dynamic> schema) {
  if (schema['type'] != 'object' || schema['properties'] is! Map) return false;
  if (schema['required'] != null && schema['required'] is! List) return false;
  const complex = {
    'oneOf',
    'anyOf',
    'allOf',
    'not',
    'if',
    'then',
    'else',
    'dependencies',
    'dependentSchemas',
    'patternProperties',
  };
  if (schema.keys.any(complex.contains)) return false;
  if ((schema['required'] as List? ?? []).any(
    (key) => !(schema['properties'] as Map).containsKey(key),
  ))
    return false;
  return (schema['properties'] as Map).values.every(
    (p) =>
        p is Map &&
        !p.keys.any(complex.contains) &&
        (p['enum'] == null || p['enum'] is List) &&
        (p['title'] == null || p['title'] is String) &&
        (p['description'] == null || p['description'] is String) &&
        (p['enum'] is List ||
            const {
              'string',
              'number',
              'integer',
              'boolean',
              'object',
              'array',
              'null',
            }.contains(p['type'])),
  );
}

/// Only declared form fields are changed; additional JSON properties survive
/// switching modes and are sent unchanged with the explicit tool invocation.
Map<String, dynamic> mcpFormArguments(
  Map<String, dynamic> schema,
  Map<String, String?> values, {
  Map<String, dynamic> base = const {},
}) {
  final result = Map<String, dynamic>.from(base);
  final required = (schema['required'] as List? ?? []).toSet();
  for (final entry in (schema['properties'] as Map).entries) {
    final name = entry.key as String;
    final p = Map<String, dynamic>.from(entry.value as Map);
    final label = p['title'] as String? ?? name;
    final text = values[name];
    if (text == null || text.isEmpty && !required.contains(name)) {
      if (required.contains(name)) throw FormatException('请填写“$label”。');
      result.remove(name);
      continue;
    }
    Object? value;
    try {
      value = p['enum'] is List
          ? jsonDecode(text)
          : switch (p['type']) {
              'string' => text,
              'integer' => int.parse(text),
              'number' => double.parse(text),
              _ => jsonDecode(text),
            };
    } catch (_) {
      throw FormatException('“$label”的内容格式不正确。');
    }
    final validType = switch (p['type']) {
      'string' => value is String,
      'integer' => value is num && value.isFinite && value % 1 == 0,
      'number' => value is num && value.isFinite,
      'boolean' => value is bool,
      'object' => value is Map,
      'array' => value is List,
      'null' => value == null,
      _ => p['enum'] is List,
    };
    if (!validType) throw FormatException('请检查“$label”的数据类型。');
    if (p['enum'] case final List choices) {
      if (!choices.any((v) => jsonEncode(v) == jsonEncode(value)))
        throw FormatException('请为“$label”选择一个有效选项。');
    }
    if (value is num) {
      if (p['minimum'] is num && value < p['minimum'] ||
          p['maximum'] is num && value > p['maximum'])
        throw FormatException('“$label”超出了工具允许的范围。');
    }
    if (value is String) {
      if (p['minLength'] is int && value.length < p['minLength'] ||
          p['maxLength'] is int && value.length > p['maxLength'])
        throw FormatException('请检查“$label”的长度。');
      if (p['pattern'] is String && !RegExp(p['pattern']).hasMatch(value))
        throw FormatException('“$label”不符合工具要求的格式。');
    }
    result[name] = value;
  }
  return result;
}

class McpArgumentsEditor extends StatefulWidget {
  const McpArgumentsEditor({
    super.key,
    required this.schema,
    required this.controller,
    this.enabled = true,
  });
  final Map<String, dynamic> schema;
  final TextEditingController controller;
  final bool enabled;
  @override
  State<McpArgumentsEditor> createState() => McpArgumentsEditorState();
}

class McpArgumentsEditorState extends State<McpArgumentsEditor> {
  bool raw = false;
  Map<String, dynamic> base = {};
  Map<String, String?> values = {};
  String? error;

  @override
  void initState() {
    super.initState();
    raw = !supportsMcpForm(widget.schema);
    if (!raw) {
      try {
        loadForm();
      } catch (_) {
        raw = true;
      }
    }
  }

  Map<String, dynamic> readJson() {
    final parsed = jsonDecode(widget.controller.text);
    if (parsed is! Map<String, dynamic>)
      throw const FormatException('参数需要填写为 JSON 对象。');
    return parsed;
  }

  void loadForm() {
    final parsed = readJson();
    final next = <String, String?>{};
    for (final e in (widget.schema['properties'] as Map).entries) {
      final p = e.value as Map;
      final present = parsed.containsKey(e.key) || p.containsKey('default');
      if (!present) continue;
      final value = parsed.containsKey(e.key) ? parsed[e.key] : p['default'];
      if (p['type'] == 'string' && p['enum'] is! List && value is! String)
        throw const FormatException('部分参数的类型需要使用 JSON 模式保留。');
      next[e.key as String] = p['type'] == 'string' && p['enum'] is! List
          ? value as String
          : jsonEncode(value);
    }
    base = parsed;
    values = next;
  }

  Map<String, dynamic> read() =>
      raw ? readJson() : mcpFormArguments(widget.schema, values, base: base);

  void switchMode() {
    try {
      if (raw) {
        loadForm();
      } else {
        widget.controller.text = const JsonEncoder.withIndent(
          '  ',
        ).convert(read());
      }
      setState(() {
        raw = !raw;
        error = null;
      });
    } catch (e) {
      setState(
        () => error = e is FormatException ? '${e.message}' : '请先检查参数内容。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final required = widget.schema['required'] is List
        ? (widget.schema['required'] as List).toSet()
        : <Object?>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '填写参数',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            if (supportsMcpForm(widget.schema))
              TextButton.icon(
                key: const ValueKey('mcp-parameter-mode'),
                onPressed: widget.enabled ? switchMode : null,
                icon: Icon(
                  raw ? Icons.list_alt_rounded : Icons.code_rounded,
                  size: 17,
                ),
                label: Text(raw ? '表单模式' : 'JSON 模式'),
              ),
          ],
        ),
        if (raw) ...[
          if (!supportsMcpForm(widget.schema))
            const Text(
              '此工具使用复杂参数，可参考下方格式填写。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          TextField(
            controller: widget.controller,
            enabled: widget.enabled,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'JSON 参数',
              border: OutlineInputBorder(),
            ),
          ),
        ] else ...[
          if ((widget.schema['properties'] as Map).isEmpty)
            const Text('此工具无需填写参数。'),
          for (final e in (widget.schema['properties'] as Map).entries)
            field(
              e.key as String,
              Map<String, dynamic>.from(e.value as Map),
              required.contains(e.key),
            ),
        ],
        if (error != null)
          Text(
            error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              height: 1.6,
            ),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('参数格式说明', style: TextStyle(fontSize: 12)),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(widget.schema),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget field(String name, Map<String, dynamic> p, bool required) {
    final title = '${p['title'] ?? name}${required ? ' *' : '（可选）'}';
    final description = p['description'] as String?;
    final choices =
        p['enum'] as List? ?? (p['type'] == 'boolean' ? [true, false] : null);
    Widget input;
    if (choices != null) {
      final options = {
        for (final v in choices)
          jsonEncode(v): v is bool ? (v ? '是' : '否') : '$v',
      };
      final current = values[name];
      input = DropdownButtonFormField<String>(
        key: ValueKey('mcp-field-$name'),
        initialValue: current ?? '__unset__',
        isExpanded: true,
        decoration: InputDecoration(
          labelText: title,
          helperText: description,
          helperMaxLines: 3,
        ),
        items: [
          const DropdownMenuItem(value: '__unset__', child: Text('请选择')),
          if (current != null && !options.containsKey(current))
            DropdownMenuItem(value: current, child: const Text('当前值（不在选项中）')),
          for (final e in options.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(
                e.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: !widget.enabled
            ? null
            : (v) => setState(() => values[name] = v == '__unset__' ? null : v),
      );
    } else {
      final structured = p['type'] == 'object' || p['type'] == 'array';
      input = TextFormField(
        key: ValueKey('mcp-field-$name'),
        initialValue: values[name],
        enabled: widget.enabled,
        minLines: structured ? 2 : 1,
        maxLines: structured ? 5 : 3,
        keyboardType: const {'number', 'integer'}.contains(p['type'])
            ? const TextInputType.numberWithOptions(signed: true, decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: title,
          helperText: description,
          helperMaxLines: 3,
          hintText: structured
              ? (p['type'] == 'object' ? 'JSON 对象，如 {}' : 'JSON 数组，如 []')
              : null,
        ),
        onChanged: (v) => values[name] = v,
      );
    }
    return Padding(padding: const EdgeInsets.only(bottom: 18), child: input);
  }
}
