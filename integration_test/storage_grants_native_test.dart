import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real SAF grants import large data, publish to chosen folder, revoke and restore without duplication',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      await app.main();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      const cloud = MethodChannel('skivu/cloud_execution');
      const plugin = MethodChannel('skivu/open_plugin_files');
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final owner = 'qa:saf:$stamp';
      final task = 'saf_$stamp';
      var serial = 0;
      Future<Map<String, dynamic>> tool(
        String name,
        Map<String, dynamic> args,
      ) async {
        final receipt = await cloud.invokeMapMethod<String, dynamic>('invoke', {
          'tool': 'coding.$name',
          'arguments': args,
          'owner': owner,
          'taskId': task,
          'requestId': 'saf_${stamp}_${++serial}',
        });
        expect(receipt?['outcome'], 'verified', reason: receipt.toString());
        return Map<String, dynamic>.from(receipt!['value'] as Map);
      }

      Future<Map<String, dynamic>> select(String method, String stage) async {
        debugPrint('SAF_QA_SELECT $stage');
        final result = await cloud.invokeMapMethod<String, dynamic>(method);
        expect(result?['id'], startsWith('storage_'));
        expect(result?['uri'], contains('engineqa.test.documents'));
        return result!;
      }

      await tester.runAsync(() async {
        final project = (await tool('projects.create', {
          'name': 'SAF actual provider $stamp',
        }))['id'];
        final folder = await select('storage.authorize', 'directory');
        final listing = await tool('storage.list', {
          'grantId': folder['id'],
          'path': '',
        });
        final original = (listing['items'] as List).cast<Map>().singleWhere(
          (v) => v['name'] == 'input-large.csv',
        );
        expect(original['bytes'], greaterThan(8 * 1024 * 1024));
        String? readId;
        var readOffset = 0, readPages = 0;
        final readHashes = <Digest>[];
        final readerHash = sha256.startChunkedConversion(
          _ListDigestSink(readHashes),
        );
        while (true) {
          final page = await tool('storage.read', {
            'grantId': folder['id'],
            'path': 'input-large.csv',
            'offset': readOffset,
            'length': 1048576,
            if (readId != null) 'readId': readId,
          });
          readId ??= page['readId'] as String;
          expect(page['readId'], readId);
          expect(page['wholeFileRehashedPerPage'], false);
          readerHash.add(utf8.encode(page['text'] as String));
          readOffset = (page['nextOffset'] as num).toInt();
          readPages++;
          if (page['complete'] == true) break;
        }
        readerHash.close();
        expect(readOffset, original['bytes']);
        expect(readPages, greaterThan(8));
        final imported = await tool('storage.import', {
          'grantId': folder['id'],
          'sourcePath': 'input-large.csv',
          'projectId': project,
          'path': 'input-large.csv',
        });
        final source = await tool('files.read', {
          'projectId': project,
          'path': 'input-large.csv',
          'length': 31,
        });
        expect(source['text'], startsWith('original,中文😀,42'));
        expect(source['bytes'], original['bytes']);
        expect(readHashes.single.toString(), source['sha256']);
        final name = 'delivered-$stamp.csv';
        final started = await tool('exec.start', {
          'projectId': project,
          'command':
              "node -e \"require('fs').copyFileSync('input-large.csv','$name')\"",
        });
        final exited = await tool('jobs.wait', {'jobId': started['id']});
        expect(exited['exitCode'], 0);
        await cloud.invokeMethod('storage.default', {'grantId': folder['id']});
        final delivered = await tool('deliver.prepare', {
          'projectId': project,
          'files': [
            {'path': name, 'purpose': '真实用户目录交付'},
          ],
        });
        expect(delivered['count'], 1);
        expect(delivered['failedCount'], 0);
        final artifact = (delivered['artifacts'] as List).single as Map;
        expect(artifact['phoneSaveState'], 'saved');
        expect(artifact['phoneUri'], contains('engineqa.test.documents'));
        expect(artifact['sha256'], source['sha256']);
        final batch = delivered['batchId'];
        await cloud.invokeMethod('storage.revoke', {'grantId': folder['id']});
        await expectLater(
          cloud.invokeMapMethod<String, dynamic>('invoke', {
            'tool': 'coding.storage.read',
            'arguments': {
              'grantId': folder['id'],
              'path': 'input-large.csv',
              'readId': readId,
              'offset': 0,
            },
            'owner': owner,
            'taskId': task,
            'requestId': 'saf_${stamp}_${++serial}',
          }),
          throwsA(isA<PlatformException>()),
        );
        var status = await tool('artifacts.status', {'batchId': batch});
        expect(status['verified'], false);
        expect(status['unavailableCount'], 1);
        final grants = await cloud.invokeListMethod<dynamic>('storage.grants');
        final revoked = (grants!.cast<Map>()).singleWhere(
          (g) => g['id'] == folder['id'],
        );
        expect(revoked['available'], false);
        expect(revoked['default'], false);
        final restored = await select('storage.authorize', 'regrant');
        expect(restored['id'], folder['id']);
        expect(
          (await tool('storage.read', {
            'grantId': folder['id'],
            'path': 'input-large.csv',
            'readId': readId,
            'length': 32,
          }))['text'],
          startsWith('original,中文😀,42'),
        );
        status = await tool('artifacts.status', {'batchId': batch});
        expect(status['verified'], true);
        expect(status['phoneSavedCount'], 1);
        final after = await tool('storage.list', {
          'grantId': restored['id'],
          'path': '',
        });
        expect(
          (after['items'] as List)
              .cast<Map>()
              .where((f) => f['name'] == name)
              .length,
          1,
        );
        final single = await select('storage.pick', 'single');
        expect(single['kind'], 'file');
        await expectLater(
          cloud.invokeMethod('storage.default', {'grantId': single['id']}),
          throwsA(isA<PlatformException>()),
        );
        debugPrint('SAF_QA_SELECT plugin-pick');
        final picked = await plugin.invokeMapMethod<String, dynamic>('pick', {
          'owner': 'plugin:saf_qa_$stamp',
        });
        expect(picked?['bytes'], greaterThan(8 * 1024 * 1024));
        expect(picked?['inlineBytes'], isNull);
        var offset = 0;
        final hashOutput = <Digest>[];
        // Every page crosses the actual platform channel; compare complete bytes.
        final complete = sha256.startChunkedConversion(
          _ListDigestSink(hashOutput),
        );
        while (true) {
          final page = await plugin.invokeMapMethod<String, dynamic>('read', {
            'owner': 'plugin:saf_qa_$stamp',
            'contentId': picked!['contentId'],
            'offset': offset,
            'length': 1048576,
          });
          complete.add(base64Decode(page!['data']));
          offset = (page['nextOffset'] as num).toInt();
          if (page['complete'] == true) break;
        }
        complete.close();
        expect(offset, picked['bytes']);
        expect(hashOutput.single.toString(), picked['sha256']);
        binding.reportData = {
          'realSafProvider': true,
          'snapshotReadBytes': readOffset,
          'snapshotReadPages': readPages,
          'snapshotSha256': readHashes.single.toString(),
          'directoryGrant': folder['id'],
          'fileGrant': single['id'],
          'sourceBytes': source['bytes'],
          'sourceSha256': source['sha256'],
          'imported': imported['path'] ?? 'input-large.csv',
          'deliveredBatch': batch,
          'savedToActualSelectedProvider': true,
          'revokeDetectedUnavailable': true,
          'regrantRestoredSameFile': true,
          'duplicateCount': 0,
          'largePluginContentPagesRead': true,
          'pluginBytes': offset,
        };
        await cloud.invokeMethod('storage.default', {'grantId': null});
        await cloud.invokeMethod('storage.revoke', {'grantId': folder['id']});
        await cloud.invokeMethod('storage.revoke', {'grantId': single['id']});
      });
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

class _ListDigestSink implements Sink<Digest> {
  _ListDigestSink(this.values);
  final List<Digest> values;
  @override
  void add(Digest value) => values.add(value);
  @override
  void close() {}
}
