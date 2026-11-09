import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'assistant_engine.dart';
import 'device_engine.dart';

/// Business extraction/source/matching stay outside generic execution state.
class ChoiceQuestion {
  ChoiceQuestion(
    this.observationId,
    this.question,
    this.options,
    this.multiple,
  );
  final String observationId, question;
  final List<Map<String, dynamic>> options;
  final bool multiple;
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            question,
            options.map((o) => o['text']).toList(),
            multiple,
          ]),
        ),
      )
      .toString();
  static String normalize(String text) {
    text = String.fromCharCodes(
      text.runes.map((r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r),
    );
    final value = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'^[a-z][.、:：)）]'), '');
    if (const {'正确', '对', 'true', '√', '✓'}.contains(value)) return '#true';
    if (const {'错误', '错', 'false', '×', '✗', '✕'}.contains(value))
      return '#false';
    return value
        .replaceAll('−', '-')
        .replaceAll('＋', '+')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'^[a-z][.、:：)）]'), '');
  }

  List<Map<String, dynamic>> candidates(String answer) {
    final a = normalize(answer);
    Set<String> pairs(String s) => {
      for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2),
    };
    final list =
        options.map((option) {
            final b = normalize(option['text']);
            final x = pairs(a), y = pairs(b);
            final signs = RegExp(r'[+\-*/=<>]');
            final sameSigns =
                signs.allMatches(a).map((m) => m[0]).join() ==
                signs.allMatches(b).map((m) => m[0]).join();
            final score = a == b
                ? 1.0
                : a.length < 4 || b.length < 4 || !sameSigns
                ? 0.0
                : x.isEmpty || y.isEmpty
                ? 0.0
                : 2 * x.intersection(y).length / (x.length + y.length);
            return <String, dynamic>{
              'text': option['text'],
              'score': score,
              'needsReview': score < 1,
            };
          }).toList()
          ..sort((a, b) => (b['score'] as num).compareTo(a['score'] as num));
    return list.take(3).toList();
  }

  List<String> match(List<String> answers) {
    final selected = <String>{};
    for (final answer in answers) {
      final letters = String.fromCharCodes(
        answer.trim().runes.map(
          (r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r,
        ),
      ).toUpperCase();
      if (RegExp(r'^[A-Z](?:[\s,，、;；]*[A-Z])*$').hasMatch(letters) &&
          letters
              .replaceAll(RegExp('[^A-Z]'), '')
              .split('')
              .every((s) => s.codeUnitAt(0) - 65 < options.length)) {
        for (final char in letters.replaceAll(RegExp('[^A-Z]'), '').split(''))
          selected.add(options[char.codeUnitAt(0) - 65]['id']);
        continue;
      }
      final exact = options
          .where((o) => normalize(o['text']) == normalize(answer))
          .toList();
      if (exact.length != 1) throw StateError('答案与当前选项没有唯一精确匹配；相似答案需要重新判断。');
      selected.add(exact.single['id']);
    }
    if (selected.isEmpty || !multiple && selected.length != 1)
      throw StateError('单选／多选答案数量不匹配。');
    return selected.toList();
  }

  static ChoiceQuestion extract(
    Map<String, dynamic> observation,
    List<String> questionIds,
    List<String> optionIds,
  ) {
    final elements = (observation['elements'] as List)
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    Map<String, dynamic> node(String id) =>
        elements.where((r) => r['id'] == id && r['password'] != true).single;
    if (questionIds.isEmpty ||
        optionIds.length < 2 ||
        optionIds.length > 26 ||
        optionIds.toSet().length != optionIds.length)
      throw StateError('题干或选项不完整。');
    final question = questionIds
        .map((id) => node(id)['text'] ?? '')
        .join('\n')
        .trim();
    final options = optionIds.map(node).toList();
    if (question.isEmpty ||
        options.any((n) => (n['text'] as String? ?? '').isEmpty))
      throw StateError('有不可读取的题干／图片选项，需要真实视觉能力或人工处理。');
    final multi = options.every(
      (n) => (n['class'] ?? '').toString().contains('CheckBox'),
    );
    if (!multi &&
        !options.every(
          (n) => (n['class'] ?? '').toString().contains('RadioButton'),
        ))
      throw StateError('未识别可验证的单选／多选控件，需要页面适配。');
    return ChoiceQuestion(
      observation['observationId'],
      question,
      options,
      multi,
    );
  }
}

class PhoneTaskAdapters implements AssistantExtensions {
  PhoneTaskAdapters(this.observation);
  final Map<String, dynamic>? Function() observation;
  ChoiceQuestion? question;
  static Map<String, dynamic> schema(
    Map<String, dynamic> properties,
    List<String> required,
  ) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  static const list = {
    'type': 'array',
    'maxItems': 26,
    'items': {'type': 'string', 'maxLength': 2000},
  };
  static final definitions = [
    {
      'id': 'adapter.choice.extract',
      'description':
          '选择题适配：从最新真实观察指定 questionIds/optionIds 提取题干、单选/多选、选项和指纹；不点击、切题或提交。图片不可读时等待真实视觉能力。',
      'parameters': schema(
        {'questionIds': list, 'optionIds': list},
        ['questionIds', 'optionIds'],
      ),
      'effect': 'read',
    },
    {
      'id': 'adapter.choice.match',
      'description':
          '把当前模型判断的答案与同一题目指纹的选项匹配，支持字母、文本和符号。不自动点击；每次点击后 ui.verify 核对选中状态，页面变化后重新观察提取。相似但不唯一时拒绝。',
      'parameters': schema(
        {
          'fingerprint': {'type': 'string'},
          'answers': list,
        },
        ['fingerprint', 'answers'],
      ),
      'effect': 'read',
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> catalog() async => definitions;
  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    check();
    try {
      final actual = observation();
      if (actual == null) throw StateError('请先观察当前页面。');
      dynamic value;
      if (tool == 'adapter.choice.extract') {
        question = ChoiceQuestion.extract(
          actual,
          List<String>.from(args['questionIds']),
          List<String>.from(args['optionIds']),
        );
        final q = question!;
        value = {
          'fingerprint': q.fingerprint,
          'question': q.question,
          'multiple': q.multiple,
          'options': q.options,
          'observationId': q.observationId,
          'answerSource': '当前模型；不保证答案必然正确',
        };
      } else {
        final q = question;
        if (q == null ||
            actual['observationId'] != q.observationId ||
            args['fingerprint'] != q.fingerprint)
          throw StateError('题目或页面已变化，旧答案失效。');
        value = {
          'elementIds': q.match(List<String>.from(args['answers'])),
          'fingerprint': q.fingerprint,
          'observationId': q.observationId,
          'requiresSelectedReadback': true,
        };
      }
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'verified',
        'summary': '已按当前题目快照处理，没有提交或切题。',
        'value': value,
      });
    } catch (e) {
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'failed',
        'summary': '$e',
        if (tool == 'adapter.choice.match' &&
            question != null &&
            args['answers'] is List)
          'value': {
            'candidates': [
              for (final answer
                  in (args['answers'] as List).whereType<String>())
                question!.candidates(answer),
            ],
            'requiresReview': true,
            'noActionDispatched': true,
          },
      });
    }
  }
}
