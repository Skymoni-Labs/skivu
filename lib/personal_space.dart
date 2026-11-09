import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'tool_execution.dart';

const personalSpaceKey = 'skivu.main.personal-space.v1';
const personalSpaceBackupKey = 'skivu.main.personal-space.backup.v1';
final personalSpace = PersonalSpaceStore();
String personalDay([DateTime? value]) {
  final d = value ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

bool validPersonalDay(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final d = DateTime.tryParse(value);
  return d != null && personalDay(d) == value;
}

class PersonalRecord {
  const PersonalRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.created,
    required this.updated,
    this.date = '',
    this.time = '',
    this.category = '生活',
    this.done = false,
    this.archived = false,
    this.revision = 1,
    this.sourceKey = '',
    this.sourceTarget = '',
    this.sourceDetail = '',
  });
  final String id, title, body, date, time, category;
  final int created, updated;
  final bool done, archived;
  final int revision;
  final String sourceKey, sourceTarget, sourceDetail;
  PersonalRecord copy({
    String? title,
    String? body,
    String? date,
    String? time,
    String? category,
    bool? done,
    bool? archived,
  }) => PersonalRecord(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    date: date ?? this.date,
    time: time ?? this.time,
    category: category ?? this.category,
    done: done ?? this.done,
    archived: archived ?? this.archived,
    revision: revision + 1,
    sourceKey: sourceKey,
    sourceTarget: sourceTarget,
    sourceDetail: sourceDetail,
    created: created,
    updated: DateTime.now().millisecondsSinceEpoch.clamp(
      updated,
      8640000000000000,
    ),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'date': date,
    'time': time,
    'category': category,
    'done': done,
    'archived': archived,
    'created': created,
    'updated': updated,
    'revision': revision,
    if (sourceKey.isNotEmpty) 'sourceKey': sourceKey,
    if (sourceTarget.isNotEmpty) 'sourceTarget': sourceTarget,
    if (sourceDetail.isNotEmpty) 'sourceDetail': sourceDetail,
  };
  factory PersonalRecord.parse(Object? raw) {
    if (raw is! Map) throw const FormatException('记录格式无效');
    final m = Map<String, dynamic>.from(raw);
    for (final k in ['id', 'title', 'body', 'date', 'time', 'category']) {
      if (m[k] is! String || (m[k] as String).contains('\u0000'))
        throw const FormatException('记录格式无效');
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(m['id']) ||
        (m['title'] as String).trim().isEmpty ||
        (m['title'] as String).length > 160 ||
        (m['body'] as String).length > 12000 ||
        (m['category'] as String).length > 40 ||
        (m['date'] != '' && !validPersonalDay(m['date'])) ||
        (m['time'] != '' &&
            (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(m['time']) ||
                m['date'] == '')) ||
        m['done'] is! bool ||
        m['archived'] is! bool ||
        m['created'] is! int ||
        m['updated'] is! int ||
        m['created'] <= 0 ||
        m['updated'] < m['created'] ||
        m['revision'] != null && (m['revision'] is! int || m['revision'] < 1) ||
        m['sourceKey'] != null &&
            (m['sourceKey'] is! String ||
                !RegExp(r'^[a-zA-Z0-9_:-]{1,240}$').hasMatch(m['sourceKey'])) ||
        m['sourceTarget'] != null &&
            m['sourceTarget'] != '' &&
            !ToolExecutionEvent.validTarget(m['sourceTarget']) ||
        m['sourceDetail'] != null &&
            (m['sourceDetail'] is! String ||
                (m['sourceDetail'] as String).length > 400 ||
                (m['sourceDetail'] as String).contains('\u0000'))) {
      throw const FormatException('记录格式无效');
    }
    return PersonalRecord(
      id: m['id'],
      title: m['title'],
      body: m['body'],
      date: m['date'],
      time: m['time'],
      category: m['category'],
      done: m['done'],
      archived: m['archived'],
      created: m['created'],
      updated: m['updated'],
      revision: m['revision'] as int? ?? 1,
      sourceKey: m['sourceKey'] as String? ?? '',
      sourceTarget: m['sourceTarget'] as String? ?? '',
      sourceDetail: m['sourceDetail'] as String? ?? '',
    );
  }
}

typedef PersonalRead = Future<String?> Function();
typedef PersonalWrite = Future<void> Function(String value);

class PersonalSpaceStore extends ChangeNotifier {
  PersonalSpaceStore({PersonalRead? read, PersonalWrite? write})
    : _read = read,
      _write = write;
  final PersonalRead? _read;
  final PersonalWrite? _write;
  List<PersonalRecord> _tasks = [], _memories = [];
  List<Map<String, String>> _receipts = [];
  String? _legacyRaw;
  List<PersonalRecord> get tasks =>
      List.unmodifiable(_tasks.where((r) => !r.archived));
  List<PersonalRecord> get memories =>
      List.unmodifiable(_memories.where((r) => !r.archived));
  List<PersonalRecord> get archivedTasks =>
      List.unmodifiable(_tasks.where((r) => r.archived));
  List<PersonalRecord> get archivedMemories =>
      List.unmodifiable(_memories.where((r) => r.archived));
  bool loaded = false;
  String? error;
  Future<void>? _loading;
  Future<void> _tail = Future.value();
  int _serial = 0;
  Future<String?> _readValue() async => _read != null
      ? _read()
      : (await SharedPreferences.getInstance()).getString(personalSpaceKey);
  Future<void> restore() => _loading ??= _restore();
  Future<void> _restore() async {
    try {
      final raw = await _readValue();
      if (raw != null) {
        if (utf8.encode(raw).length > 4 * 1024 * 1024)
          throw const FormatException('记录过大');
        final v = jsonDecode(raw);
        if (v is! Map ||
            !{1, 2}.contains(v['version']) ||
            v['tasks'] is! List ||
            v['memories'] is! List)
          throw const FormatException('记录格式无效');
        final tasks = (v['tasks'] as List).map(PersonalRecord.parse).toList();
        final memories = (v['memories'] as List)
            .map(PersonalRecord.parse)
            .toList();
        for (final rows in [tasks, memories]) {
          if (rows.map((r) => r.id).toSet().length != rows.length)
            throw const FormatException('记录重复');
        }
        _tasks = tasks;
        _memories = memories;
        if (v['version'] == 1) _legacyRaw = raw;
        final receipts = v['receipts'];
        if (receipts != null) {
          if (receipts is! List || receipts.length > 256)
            throw const FormatException('回执格式无效');
          _receipts = receipts.map((r) {
            if (r is! Map ||
                r.keys.toSet().difference({
                  'id',
                  'digest',
                  'taskId',
                }).isNotEmpty ||
                r['id'] is! String ||
                !RegExp(r'^[a-zA-Z0-9_:-]{1,180}$').hasMatch(r['id']) ||
                r['digest'] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(r['digest']) ||
                r['taskId'] is! String ||
                !tasks.any((t) => t.id == r['taskId']))
              throw const FormatException('回执格式无效');
            return Map<String, String>.from(r);
          }).toList();
          if (_receipts.map((r) => r['id']).toSet().length != _receipts.length)
            throw const FormatException('回执重复');
        }
      }
      error = null;
    } catch (_) {
      error = '个人空间存档暂时无法读取，原有内容已保留。聊天仍可正常使用。';
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _change(
    void Function(List<PersonalRecord>, List<PersonalRecord>) edit, {
    String? operationId,
    String? digest,
    String Function()? resultId,
    void Function(PersonalRecord)? reuse,
    void Function()? check,
  }) {
    final work = _tail.then((_) async {
      await restore();
      if (error != null) throw StateError(error!);
      check?.call();
      if (operationId != null) {
        final previous = _receipts
            .where((r) => r['id'] == operationId)
            .firstOrNull;
        if (previous != null) {
          if (previous['digest'] != digest) throw StateError('同一操作编号不能用于不同内容。');
          reuse!(_tasks.firstWhere((t) => t.id == previous['taskId']));
          return;
        }
      }
      final tasks = [..._tasks], memories = [..._memories];
      edit(tasks, memories);
      final receipts = [..._receipts];
      if (operationId != null)
        receipts.add({
          'id': operationId,
          'digest': digest!,
          'taskId': resultId!(),
        });
      final retained = receipts
          .skip((receipts.length - 256).clamp(0, receipts.length))
          .toList();
      final value = jsonEncode({
        'version': 2,
        'tasks': tasks.map((r) => r.toJson()).toList(),
        'memories': memories.map((r) => r.toJson()).toList(),
        'receipts': retained,
      });
      if (utf8.encode(value).length > 4 * 1024 * 1024)
        throw StateError('记录空间已满，请先整理不需要的记录。');
      if (_write != null) {
        check?.call();
        await _write(value);
      } else {
        final prefs = await SharedPreferences.getInstance();
        check?.call();
        if (_legacyRaw != null && !prefs.containsKey(personalSpaceBackupKey)) {
          if (!await prefs.setString(personalSpaceBackupKey, _legacyRaw!))
            throw StateError('旧记录备份未完成，未升级存档。');
          check?.call();
        }
        if (!await prefs.setString(personalSpaceKey, value))
          throw StateError('保存未完成，请重试。');
      }
      _tasks = tasks;
      _memories = memories;
      _receipts = retained;
      _legacyRaw = null;
      notifyListeners();
    });
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<void> save({
    required bool memory,
    String? id,
    required String title,
    String body = '',
    String date = '',
    String time = '',
    String category = '生活',
    int? expectedRevision,
  }) => _change((tasks, memories) {
    if (title.trim().isEmpty ||
        title.length > 160 ||
        body.length > 12000 ||
        category.length > 40 ||
        [title, body, category].any((value) => value.contains('\u0000')) ||
        (memory && body.trim().isEmpty))
      throw StateError('请补全标题和内容。');
    if ((date.isNotEmpty && !validPersonalDay(date)) ||
        (time.isNotEmpty &&
            (date.isEmpty ||
                !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time))))
      throw StateError('请检查日期和时间。');
    final rows = memory ? memories : tasks;
    final index = rows.indexWhere((r) => r.id == id);
    if (id != null && index < 0) throw StateError('记录已变化，请重新打开。');
    if (index >= 0) {
      if (expectedRevision != null && rows[index].revision != expectedRevision)
        throw StateError('任务已在其他位置修改，请重新打开。');
      rows[index] = rows[index].copy(
        title: title.trim(),
        body: body.trim(),
        date: date,
        time: time,
        category: category.trim().isEmpty ? '生活' : category.trim(),
      );
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      var nextId = '${now}_${++_serial}';
      while (rows.any((record) => record.id == nextId)) {
        nextId = '${now}_${++_serial}';
      }
      rows.add(
        PersonalRecord(
          id: nextId,
          title: title.trim(),
          body: body.trim(),
          date: date,
          time: time,
          category: category.trim().isEmpty ? '生活' : category.trim(),
          created: now,
          updated: now,
        ),
      );
    }
  });
  Future<void> toggle(String id) => _change((tasks, _) {
    final i = tasks.indexWhere((r) => r.id == id);
    if (i < 0) throw StateError('任务已变化');
    tasks[i] = tasks[i].copy(done: !tasks[i].done);
  });

  PersonalRecord? task(String id) =>
      _tasks.where((r) => r.id == id).firstOrNull;
  PersonalRecord? taskForSource(String key) =>
      key.isEmpty ? null : _tasks.where((r) => r.sourceKey == key).firstOrNull;

  /// Local-only, atomic task edits. This never sets a system alarm or schedules work.
  Future<PersonalRecord> applyTask(
    String action,
    Map<String, dynamic> args,
    String operationId, {
    void Function()? check,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_:-]{1,180}$').hasMatch(operationId))
      throw const FormatException('任务操作编号无效。');
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode([action, _canonical(args)])))
        .toString();
    late PersonalRecord result;
    await _change(
      (tasks, _) {
        if (action == 'create' || action == 'attach') {
          final now = DateTime.now().millisecondsSinceEpoch;
          final source = args['sourceKey'] as String? ?? '';
          final candidate = PersonalRecord.parse(
            PersonalRecord(
              id: '${now}_${++_serial}',
              title: (args['title'] as String).trim(),
              body: (args['body'] as String? ?? '').trim(),
              date: args['date'] as String? ?? '',
              time: args['time'] as String? ?? '',
              category: args['category'] as String? ?? '生活',
              created: now,
              updated: now,
              done: action == 'attach',
              sourceKey: source,
              sourceTarget: args['sourceTarget'] as String? ?? '',
              sourceDetail: args['sourceDetail'] as String? ?? '',
            ).toJson(),
          );
          final existing = tasks
              .where(
                (t) => source.isNotEmpty
                    ? t.sourceKey == source
                    : !t.archived &&
                          !t.done &&
                          t.title == candidate.title &&
                          t.body == candidate.body &&
                          t.date == candidate.date &&
                          t.time == candidate.time &&
                          t.category == candidate.category,
              )
              .firstOrNull;
          result = existing ?? candidate;
          if (existing == null) tasks.add(candidate);
        } else {
          final index = tasks.indexWhere((t) => t.id == args['id']);
          if (index < 0) throw StateError('没有找到这条任务。');
          final current = tasks[index];
          final PersonalRecord next;
          if (action == 'complete') {
            if (current.done == args['done']) {
              result = current;
              return;
            }
            next = current.copy(done: args['done'] as bool);
          } else if (action == 'archive') {
            if (current.archived == args['archived']) {
              result = current;
              return;
            }
            next = current.copy(archived: args['archived'] as bool);
          } else if (action == 'update') {
            next = current.copy(
              title: (args['title'] as String?)?.trim(),
              body: (args['body'] as String?)?.trim(),
              date: args['date'] as String?,
              time: args['time'] as String?,
              category: args['category'] as String?,
            );
            if ([
                  next.title,
                  next.body,
                  next.date,
                  next.time,
                  next.category,
                ].join('\u0000') ==
                [
                  current.title,
                  current.body,
                  current.date,
                  current.time,
                  current.category,
                ].join('\u0000')) {
              result = current;
              return;
            }
          } else {
            throw const FormatException('不支持的任务操作。');
          }
          if (current.revision != args['expectedRevision'])
            throw StateError('任务已在其他位置修改。请重新读取后处理，未覆盖新内容。');
          result = PersonalRecord.parse(next.toJson());
          tasks[index] = result;
        }
      },
      operationId: operationId,
      digest: fingerprint,
      resultId: () => result.id,
      reuse: (r) => result = r,
      check: check,
    );
    return result;
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _canonical(value[k])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  Future<void> archive(
    String id, {
    required bool memory,
    bool archived = true,
    int? expectedRevision,
  }) => _change((tasks, memories) {
    final rows = memory ? memories : tasks;
    final i = rows.indexWhere((r) => r.id == id);
    if (i < 0) throw StateError('记录已变化');
    if (expectedRevision != null && rows[i].revision != expectedRevision)
      throw StateError('记录已在其他位置修改，请重新打开。');
    rows[i] = rows[i].copy(archived: archived);
  });
}
