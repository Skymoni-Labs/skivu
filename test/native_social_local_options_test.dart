import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/native_social_local_options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'social fonts and local preview toggles persist without changing global appearance',
    () async {
      final before = appearance.values;
      final options = NativeSocialLocalOptions();
      await options.restore();
      await options.setFont(18);
      await options.setNotification(false);
      await options.setQuiet(true);
      await options.setNote('本机随手记');
      final reopened = NativeSocialLocalOptions();
      await reopened.restore();
      expect(reopened.fontSize, 18);
      expect(reopened.notifications, isFalse);
      expect(reopened.quiet, isTrue);
      expect(reopened.note, '本机随手记');
      expect(appearance.values, before);
      await reopened.setFont(900);
      expect(reopened.fontSize, 18);
      options.dispose();
      reopened.dispose();
    },
  );
}
