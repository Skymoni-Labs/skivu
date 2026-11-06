import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/widgets.dart' as widgets;
import 'appearance_test.dart' show MemoryAppearance;

void main() {
  testWidgets('label uses the requested foreground color', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: widgets.label('对比文字', color: Colors.white)),
    );
    expect(tester.widget<Text>(find.text('对比文字')).style!.color, Colors.white);
  });
  test(
    'rejected starry preference is ignored while existing image settings remain',
    () async {
      final disk = MemoryAppearance()
        ..saved = {
          'useDefaultBackground': true,
          'backgroundEnabled': true,
          'backgroundOpacity': .83,
          'videoAsset': '',
          'inputFont': 'serif',
          'inputText': 0xff234567,
          'inputTextEnabled': true,
        };
      final model = AppearancePreferences(persistence: disk);
      await model.restore();
      expect(model.values.containsKey('useDefaultBackground'), isFalse);
      expect(model.flag('backgroundEnabled'), isTrue);
      expect(model.number('backgroundOpacity'), .83);
      expect(model.text('inputFont'), 'serif');
      expect(model.textColor('inputText'), const Color(0xff234567));
      model.dispose();
    },
  );
}
