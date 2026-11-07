import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EngineSelectableApp {
  EngineSelectableApp(Map<String, dynamic> value)
    : package = value['package'] as String,
      name = value['name'] as String? ?? value['package'] as String,
      sortName =
          (value['sortName'] as String? ?? value['name'] as String? ?? '')
              .toLowerCase(),
      searchName = (value['searchName'] as String? ?? '').toLowerCase();

  final String package, name, sortName, searchName;
  String get letter {
    final first = sortName.isEmpty ? '' : sortName[0].toUpperCase();
    return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
  }

  bool matches(String query) {
    final text = '$name $package $searchName'.toLowerCase();
    return text.contains(query) ||
        text
            .replaceAll(RegExp(r'\s+'), '')
            .contains(query.replaceAll(RegExp(r'\s+'), ''));
  }
}

/// This page changes only the package allowlist, and only after a checkbox tap.
class EngineAppSelectionPage extends StatefulWidget {
  const EngineAppSelectionPage({
    super.key,
    required this.apps,
    required this.selected,
    required this.save,
    this.selectedOnly = false,
  });

  final List<Map<String, dynamic>> apps;
  final Set<String> selected;
  final Future<Set<String>> Function(Set<String> packages) save;
  final bool selectedOnly;

  @override
  State<EngineAppSelectionPage> createState() => _EngineAppSelectionPageState();
}

class _EngineAppSelectionPageState extends State<EngineAppSelectionPage> {
  final search = TextEditingController();
  late final List<EngineSelectableApp> apps;
  late Set<String> selected;
  late bool selectedOnly;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    selected = Set.of(widget.selected);
    selectedOnly = widget.selectedOnly;
    apps = widget.apps.map(EngineSelectableApp.new).toList()
      ..sort((a, b) {
        if ((a.letter == '#') != (b.letter == '#')) {
          return a.letter == '#' ? 1 : -1;
        }
        final byName = a.sortName.compareTo(b.sortName);
        return byName != 0 ? byName : a.package.compareTo(b.package);
      });
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> toggle(EngineSelectableApp app, bool value) async {
    if (saving) return;
    final next = Set<String>.of(selected);
    if (value) {
      next.add(app.package);
    } else {
      next.remove(app.package);
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await widget.save(next);
      if (mounted) setState(() => selected = Set.of(saved));
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is PlatformException
              ? e.message ?? '保存未完成，请重试。'
              : '保存未完成，请重试。';
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = search.text.trim().toLowerCase();
    final filtered = apps
        .where((app) => !selectedOnly || selected.contains(app.package))
        .where((app) => query.isEmpty || app.matches(query))
        .toList();
    final rows = <Object>[];
    String? previous;
    for (final app in filtered) {
      if (app.letter != previous) rows.add(previous = app.letter);
      rows.add(app);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('选择软件')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                key: const ValueKey('engine-app-search'),
                controller: search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索名称、拼音或包名',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () => setState(search.clear),
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: Text('全部 ${apps.length}'),
                      selected: !selectedOnly,
                      onSelected: (_) => setState(() => selectedOnly = false),
                    ),
                    ChoiceChip(
                      label: Text('已选 ${selected.length}'),
                      selected: selectedOnly,
                      onSelected: (_) => setState(() => selectedOnly = true),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.sort_by_alpha, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '名称 A–Z · 中文按拼音',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '${filtered.length} 个',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 3,
              child: saving ? const LinearProgressIndicator() : null,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        query.isNotEmpty
                            ? '没有找到匹配的软件'
                            : selectedOnly
                            ? '还没有选择软件'
                            : '暂无可选择的软件',
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('engine-app-results'),
                      padding: const EdgeInsets.only(bottom: 16),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        if (row is String) {
                          return Container(
                            key: ValueKey('engine-app-letter-$row'),
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                            color: theme.colorScheme.surfaceContainerLow,
                            child: Text(
                              row,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          );
                        }
                        final app = row as EngineSelectableApp;
                        return CheckboxListTile(
                          key: ValueKey('engine-app-${app.package}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          title: Text(app.name),
                          subtitle: Text(
                            app.package,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: selected.contains(app.package),
                          onChanged: saving
                              ? null
                              : (v) => toggle(app, v == true),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
