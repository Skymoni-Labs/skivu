import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Platform.environment['SKIVU_EXECUTION_OUTPUT'];
  if (output == null || output.isEmpty) {
    throw StateError(
      'Set SKIVU_EXECUTION_OUTPUT to the local review directory.',
    );
  }
  final directory = Directory(output);
  await directory.create(recursive: true);
  await integrationDriver(
    responseDataCallback: (data) async {
      final receipt = {...?data}..remove('screenshots');
      await File(
        '${directory.path}/native-acceptance.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(receipt));
    },
    writeResponseOnFailure: true,
  );
}
