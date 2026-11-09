import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final output = Platform.environment['SKIVU_SCHEDULING_OUTPUT'];
  if (output == null) throw StateError('Set SKIVU_SCHEDULING_OUTPUT.');
  await Directory(output).create(recursive: true);
  await integrationDriver(
    timeout: const Duration(minutes: 12),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      await File('$output/integration.json').writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({...?data}..remove('screenshots')),
      );
    },
  );
}
