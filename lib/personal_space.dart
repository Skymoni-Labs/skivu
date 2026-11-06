import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const personalSpaceKey = 'skivu.main.personal-space.v1';
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
  });
  final String id, title, body, date, time, category;
  final int created, updated;
  final bool done, archived;
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
        m['updated'] < m['created']) {
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
            v['version'] != 1 ||
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
      }
      error = null;
    } catch (_) {
      error = '个人空间存档暂时无法读取，原有内容已保留。聊天仍可正常使用。';
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _change(
    void Function(List<PersonalRecord>, List<PersonalRecord>) edit,
  ) {
    final work = _tail.then((_) async {
      await restore();
      if (error != null) throw StateError(error!);
      final tasks = [..._tasks], memories = [..._memories];
      edit(tasks, memories);
      final value = jsonEncode({
        'version': 1,
        'tasks': tasks.map((r) => r.toJson()).toList(),
        'memories': memories.map((r) => r.toJson()).toList(),
      });
      if (utf8.encode(value).length > 4 * 1024 * 1024)
        throw StateError('记录空间已满，请先整理不需要的记录。');
      if (_write != null) {
        await _write(value);
      } else {
        if (!await (await SharedPreferences.getInstance()).setString(
          personalSpaceKey,
          value,
        ))
          throw StateError('保存未完成，请重试。');
      }
      _tasks = tasks;
      _memories = memories;
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
  Future<void> archive(
    String id, {
    required bool memory,
    bool archived = true,
  }) => _change((tasks, memories) {
    final rows = memory ? memories : tasks;
    final i = rows.indexWhere((r) => r.id == id);
    if (i < 0) throw StateError('记录已变化');
    rows[i] = rows[i].copy(archived: archived);
  });
}
