import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled prompt plugin follows the current prompt-only release', () {
    final package =
        jsonDecode(
              File('assets/plugins/skivu-purge.skivu.json').readAsStringSync(),
            )
            as Map;
    final manifest = package['manifest'] as Map;
    expect(manifest['id'], 'org.skivu.purge');
    expect(manifest['version'], '1.1.1');
    expect((manifest['permissions'] as List).toSet(), {'prompt', 'storage'});
    expect((package['files'] as Map).length, 4);
  });
}
