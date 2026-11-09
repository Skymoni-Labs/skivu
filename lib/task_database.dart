import 'dart:async';
import 'package:flutter/services.dart';
import 'task_database_support_stub.dart'
    if (dart.library.io) 'task_database_support_io.dart'
    as support;

class TaskSnapshot {
  const TaskSnapshot(this.version, this.value);
  final int version;
  final String? value;
  factory TaskSnapshot.parse(Map value) =>
      TaskSnapshot(value['version'] as int, value['value'] as String?);
}

abstract class TaskPersistence {
  Future<TaskSnapshot> read();
  Future<TaskSnapshot> initialize(String value);
  Future<bool> compareAndSet(int version, String value);
}

/// One native SQLite database shared by the visible and headless Flutter engines.
class TaskDatabase implements TaskPersistence {
  TaskDatabase({
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
    transport,
  }) : _transport = transport;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  _transport;
  static final instance = TaskDatabase();
  static const channel = MethodChannel('skivu/tasks');
  static bool get supported => support.taskDatabaseSupported;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  Map<String, dynamic>? lease;
  bool _attached = false;
  void attach() {
    if (_attached) return;
    _attached = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _changes.add(null);
    });
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_transport != null)
      return _transport(method, {...args, if (lease != null) '_lease': lease});
    attach();
    final value = await channel.invokeMapMethod<String, dynamic>(method, {
      ...args,
      if (lease != null) '_lease': lease,
    });
    if (value == null) throw StateError('任务数据库没有返回结果。');
    return value;
  }

  @override
  Future<TaskSnapshot> read() async =>
      TaskSnapshot.parse(await call('document.read'));
  @override
  Future<TaskSnapshot> initialize(String value) async =>
      TaskSnapshot.parse(await call('document.initialize', {'value': value}));
  @override
  Future<bool> compareAndSet(int version, String value) async =>
      (await call('document.cas', {
        'version': version,
        'value': value,
      }))['saved'] ==
      true;
}
