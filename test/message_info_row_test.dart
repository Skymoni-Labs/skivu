import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/message_info_row.dart';
import 'package:ski/state.dart';

void main() {
  testWidgets('reply info stays on one line with long names and large counts', (
    tester,
  ) async {
    final original = appearance.values;
    addTearDown(() {
      for (final entry in original.entries) {
        appearance.set(entry.key, entry.value);
      }
    });
    for (final key in [
      'showModel',
      'showProvider',
      'showTokens',
      'showElapsed',
      'showTime',
    ]) {
      appearance.set(key, true);
    }
    final message =
        Message(false, '回复', created: DateTime(2026, 10, 23, 16, 39))
          ..modelName = 'deepseek-v4.1-flash-long-custom-model-name'
          ..provider = 'Skymoni 自定义供应商'
          ..tokens = 1234567
          ..elapsedMs = 4785;
    for (final width in [150.0, 210.0, 280.0, 398.0]) {
      for (final scale in [.8, 1.0, 1.4]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: MessageInfoRow(
                    key: const ValueKey('info'),
                    message: message,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$width / $scale');
        final row = tester.getRect(find.byKey(const ValueKey('info')));
        final model = find.byKey(const ValueKey('message-info-name-0'));
        final time = find.byKey(const ValueKey('message-info-metric-2'));
        expect(tester.getTopLeft(model).dx, closeTo(row.left, .01));
        expect(tester.getBottomRight(time).dx, closeTo(row.right, .01));
        for (final label in ['1.2M tok', '4.79s', '16:39']) {
          final rect = tester.getRect(find.text(label));
          expect(rect.left, greaterThanOrEqualTo(row.left));
          expect(rect.right, lessThanOrEqualTo(row.right + .01));
          expect(rect.center.dy, closeTo(tester.getCenter(model).dy, .1));
        }
        expect(tester.widget<Text>(model).overflow, TextOverflow.ellipsis);
        expect(find.byTooltip(message.modelName!), findsOneWidget);
        expect(find.byTooltip('Token 1234567'), findsOneWidget);
      }
    }
    expect(message.tokens, 1234567);
    expect(message.modelName, 'deepseek-v4.1-flash-long-custom-model-name');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hidden fields consume no space; individual fields remain usable',
    (tester) async {
      final original = appearance.values;
      addTearDown(() {
        for (final entry in original.entries) {
          appearance.set(entry.key, entry.value);
        }
      });
      final keys = [
        'showModel',
        'showProvider',
        'showTokens',
        'showElapsed',
        'showTime',
      ];
      Future<void> render() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              child: SizedBox(
                width: 180,
                child: MessageInfoRow(
                  key: const ValueKey('info'),
                  message: Message(false, '回复'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      for (final key in keys) {
        appearance.set(key, false);
      }
      await render();
      expect(tester.getSize(find.byKey(const ValueKey('info'))).height, 0);
      for (final key in keys) {
        appearance.set(key, true);
        await render();
        expect(tester.takeException(), isNull, reason: key);
        expect(
          tester.getSize(find.byKey(const ValueKey('info'))).height,
          greaterThan(0),
        );
        appearance.set(key, false);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
