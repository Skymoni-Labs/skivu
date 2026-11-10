import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/mcp_arguments_editor.dart';

Map<String, dynamic> schema() => {
  'type': 'object',
  'required': ['query'],
  'properties': {
    'query': {'type': 'string', 'title': '搜索内容', 'minLength': 1},
    'limit': {'type': 'integer', 'title': '数量', 'minimum': 0},
    'exact': {'type': 'boolean', 'title': '精确匹配', 'default': false},
    'level': {
      'type': 'string',
      'title': '范围',
      'enum': ['small', 'large'],
      'default': 'small',
    },
  },
};

void main() {
  testWidgets('malformed third-party field metadata falls back to JSON', (
    tester,
  ) async {
    final key = GlobalKey<McpArgumentsEditorState>();
    final controller = TextEditingController(
      text: '{"query":"kept","extra":7}',
    );
    addTearDown(controller.dispose);
    for (final malformed in [
      {...schema(), 'required': 'query'},
      {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'enum': 'bad'},
        },
      },
      {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'title': []},
        },
      },
    ]) {
      expect(supportsMcpForm(malformed), isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: McpArgumentsEditor(
              key: key,
              schema: malformed,
              controller: controller,
            ),
          ),
        ),
      );
      expect(key.currentState!.read(), {'query': 'kept', 'extra': 7});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
  test(
    'form produces typed parameters and preserves additional properties',
    () {
      expect(
        mcpFormArguments(
          schema(),
          {
            'query': 'hello',
            'limit': '0',
            'exact': 'false',
            'level': '"large"',
          },
          base: {
            'extra': {'untouched': true},
          },
        ),
        {
          'extra': {'untouched': true},
          'query': 'hello',
          'limit': 0,
          'exact': false,
          'level': 'large',
        },
      );
    },
  );
  test('missing required values and invalid typed inputs are blocked', () {
    expect(() => mcpFormArguments(schema(), {}), throwsFormatException);
    for (final values in [
      {'query': 'x', 'limit': '1.5'},
      {'query': 'x', 'limit': '-1'},
      {'query': 'x', 'exact': '1'},
      {'query': 'x', 'level': '"unknown"'},
    ]) {
      expect(() => mcpFormArguments(schema(), values), throwsFormatException);
    }
  });
  test('optional blank fields are omitted while unknown JSON keys remain', () {
    expect(
      mcpFormArguments(
        schema(),
        {'query': 'x', 'limit': ''},
        base: {'limit': 2, 'extra': 7},
      ),
      {'query': 'x', 'extra': 7},
    );
  });
  test(
    'objects and arrays keep their structure and complex schemas use JSON',
    () {
      expect(
        mcpFormArguments(
          {
            'type': 'object',
            'properties': {
              'data': {'type': 'object'},
              'items': {'type': 'array'},
            },
          },
          {'data': '{"a":false}', 'items': '[0,"x"]'},
        ),
        {
          'data': {'a': false},
          'items': [0, 'x'],
        },
      );
      expect(supportsMcpForm({...schema(), 'oneOf': []}), isFalse);
    },
  );
  testWidgets('small dark form switches to JSON and back without losing data', (
    tester,
  ) async {
    final key = GlobalKey<McpArgumentsEditorState>();
    final controller = TextEditingController(
      text: '{"extra":{"untouched":true}}',
    );
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: McpArgumentsEditor(
              key: key,
              schema: schema(),
              controller: controller,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('mcp-field-query')),
      'hello',
    );
    await tester.enterText(find.byKey(const ValueKey('mcp-field-limit')), '12');
    expect(key.currentState!.read()['exact'], false);
    await tester.ensureVisible(
      find.byKey(const ValueKey('mcp-parameter-mode')),
    );
    await tester.tap(find.byKey(const ValueKey('mcp-parameter-mode')));
    await tester.pumpAndSettle();
    expect(jsonDecode(controller.text)['extra'], {'untouched': true});
    expect(jsonDecode(controller.text)['limit'], 12);
    controller.text =
        '{"query":"changed","exact":false,"extra":{"untouched":true},"level":"large"}';
    await tester.tap(find.byKey(const ValueKey('mcp-parameter-mode')));
    await tester.pumpAndSettle();
    expect(key.currentState!.read(), {
      'query': 'changed',
      'exact': false,
      'extra': {'untouched': true},
      'level': 'large',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
