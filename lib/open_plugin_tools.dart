// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

/// Bounded JSON-schema subset shared by every role companion, independent of ID.
void validatePluginSchema(Object? raw, {int depth = 0}) {
  if (depth > 6 ||
      raw is! Map ||
      raw.keys.any(
        (k) => !{
          'type',
          'properties',
          'required',
          'additionalProperties',
          'items',
          'enum',
          'maxLength',
          'maxItems',
          'description',
        }.contains(k),
      )) {
    throw const FormatException('工具参数结构不受支持。');
  }
  if (!{
    'object',
    'array',
    'string',
    'number',
    'integer',
    'boolean',
  }.contains(raw['type']))
    throw const FormatException('工具参数类型不受支持。');
  if (raw['description'] != null &&
      (raw['description'] is! String ||
          (raw['description'] as String).length > 1000))
    throw const FormatException('参数说明过长。');
  if (raw['enum'] != null &&
      (raw['enum'] is! List ||
          (raw['enum'] as List).isEmpty ||
          (raw['enum'] as List).length > 64 ||
          (raw['enum'] as List).any((v) => v is Map || v is List)))
    throw const FormatException('参数枚举不正确。');
  for (final key in ['maxLength', 'maxItems']) {
    if (raw[key] != null &&
        (raw[key] is! int ||
            raw[key] < 1 ||
            raw[key] > (key == 'maxItems' ? 100 : 12000)))
      throw const FormatException('参数上限不正确。');
  }
  if (raw['type'] == 'object') {
    final properties = raw['properties'];
    if (properties is! Map ||
        properties.length > 30 ||
        raw['required'] is! List ||
        raw['additionalProperties'] is! bool)
      throw const FormatException('工具对象需要明确字段。');
    if ((raw['required'] as List).any(
      (key) => key is! String || !properties.containsKey(key),
    ))
      throw const FormatException('必需参数不正确。');
    for (final entry in properties.entries) {
      if (entry.key is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,79}$').hasMatch(entry.key))
        throw const FormatException('参数名不正确。');
      validatePluginSchema(entry.value, depth: depth + 1);
    }
  }
  if (raw['type'] == 'array')
    validatePluginSchema(raw['items'], depth: depth + 1);
}

void validatePluginArguments(Object? value, Map schema, {int depth = 0}) {
  if (depth > 16 || utf8.encode(jsonEncode(value)).length > 32768)
    throw const FormatException('工具参数超过上限。');
  final valid = switch (schema['type']) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'integer' => value is int,
    'number' => value is num && value.isFinite,
    'boolean' => value is bool,
    _ => false,
  };
  if (!valid ||
      (schema['enum'] is List && !(schema['enum'] as List).contains(value)))
    throw const FormatException('工具参数与声明不符。');
  if (value is String &&
      (value.length > (schema['maxLength'] ?? 12000) ||
          value.contains('\u0000')))
    throw const FormatException('工具文字参数过长。');
  if (value is List) {
    if (value.length > (schema['maxItems'] ?? 100))
      throw const FormatException('工具数组过长。');
    for (final item in value)
      validatePluginArguments(item, schema['items'], depth: depth + 1);
  }
  if (value is Map) {
    final props = schema['properties'] as Map;
    if (value.length > 100 ||
        value.keys.any(
          (key) =>
              key is! String ||
              {'__proto__', 'prototype', 'constructor'}.contains(key),
        ))
      throw const FormatException('工具对象字段不正确。');
    if ((schema['required'] as List).any((key) => !value.containsKey(key)) ||
        schema['additionalProperties'] == false &&
            value.keys.any((key) => !props.containsKey(key)))
      throw const FormatException('工具参数字段不符。');
    for (final entry in value.entries) {
      if (props.containsKey(entry.key))
        validatePluginArguments(
          entry.value,
          props[entry.key],
          depth: depth + 1,
        );
    }
  }
}

void validateRoleCompanion(Object? raw) {
  if (raw is! Map ||
      raw.length != 3 ||
      raw['title'] is! String ||
      (raw['title'] as String).isEmpty ||
      (raw['title'] as String).length > 80 ||
      raw['entry'] is! String ||
      raw['tools'] is! List ||
      (raw['tools'] as List).isEmpty ||
      (raw['tools'] as List).length > 20)
    throw const FormatException('角色随身插件声明不正确。');
  final ids = <String>{};
  for (final tool in raw['tools']) {
    if (tool is! Map ||
        tool.length != 4 ||
        tool['id'] is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{0,59}$').hasMatch(tool['id']) ||
        !ids.add(tool['id']) ||
        tool['description'] is! String ||
        (tool['description'] as String).isEmpty ||
        (tool['description'] as String).length > 1200 ||
        !{'read', 'write', 'external'}.contains(tool['effect']))
      throw const FormatException('角色工具声明不正确。');
    validatePluginSchema(tool['parameters']);
    if (tool['parameters']['type'] != 'object')
      throw const FormatException('工具参数必须为对象。');
  }
}
