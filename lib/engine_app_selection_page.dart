import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'app_alphabet_ruler.dart';
import 'drawer_motion.dart';
import 'glass.dart';
import 'state.dart' show demo;

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

/// Changes only the supplied package selection after an explicit checkbox tap.
class EngineAppSelectionPage extends StatefulWidget {
  const EngineAppSelectionPage({
    super.key,
    required this.apps,
    required this.selected,
    required this.save,
    this.selectedOnly = false,
    this.title = '选择软件',
    this.prompt = '选择你允许操作的应用',
    this.selectedDescription = '已加入允许操作的范围',
    this.unselectedDescription = '尚未加入允许操作的范围',
    this.editManually,
  });

  final List<Map<String, dynamic>> apps;
  final Set<String> selected;
  final Future<Set<String>> Function(Set<String> packages) save;
  final bool selectedOnly;
  final String title, prompt, selectedDescription, unselectedDescription;
  final Future<Set<String>?> Function(Set<String> packages)? editManually;

  @override
  State<EngineAppSelectionPage> createState() => _EngineAppSelectionPageState();
}

class _EngineAppSelectionPageState extends State<EngineAppSelectionPage>
    with SingleTickerProviderStateMixin {
  final search = TextEditingController();
  final scroll = ScrollController();
  final currentLetter = ValueNotifier<String>('');
  Map<String, double> sectionOffsets = {};
  Drag? browsing;
  late final motion = DrawerMotion(vsync: this);
  late final List<EngineSelectableApp> apps;
  late Set<String> selected;
  late bool selectedOnly;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    scroll.addListener(syncCurrentLetter);
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
    browsing?.cancel();
    search.dispose();
    scroll.dispose();
    currentLetter.dispose();
    motion.dispose();
    super.dispose();
  }

  void syncCurrentLetter() {
    if (!mounted || sectionOffsets.isEmpty || !scroll.hasClients) return;
    var letter = sectionOffsets.keys.first;
    for (final entry in sectionOffsets.entries) {
      if (entry.value > scroll.offset + .5) break;
      letter = entry.key;
    }
    if (currentLetter.value != letter) currentLetter.value = letter;
  }

  void filterChanged(VoidCallback action) {
    setState(action);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void showAppInfo(EngineSelectableApp app) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SelectableText(app.package),
            const SizedBox(height: 16),
            Text(
              selected.contains(app.package)
                  ? widget.selectedDescription
                  : widget.unselectedDescription,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
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
    final groupOffsets = <String, double>{};
    final rowHeight = math.max(
      76.0,
      MediaQuery.textScalerOf(context).scale(16) * 2.6 + 20,
    );
    final groupHeight = math.max(
      36.0,
      MediaQuery.textScalerOf(context).scale(13) + 18,
    );
    var offset = 8.0;
    String? previous;
    for (final app in filtered) {
      if (app.letter != previous) {
        groupOffsets[app.letter] = offset;
        rows.add(previous = app.letter);
        offset += groupHeight;
      }
      rows.add(app);
      offset += rowHeight;
    }
    if (!mapEquals(sectionOffsets, groupOffsets)) {
      sectionOffsets = groupOffsets;
      WidgetsBinding.instance.addPostFrameCallback((_) => syncCurrentLetter());
    }

    final colors = theme.colorScheme;
    final backdropInk = demo.dark
        ? const Color(0xffe5eefb)
        : colors.onSurfaceVariant;
    return SkiGlassScene(
      motion: motion,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          foregroundColor: demo.dark
              ? const Color(0xffeef3fc)
              : colors.onSurface,
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.editManually != null)
              IconButton(
                tooltip: '手动编辑包名',
                icon: const Icon(Icons.edit_note_rounded),
                onPressed: saving
                    ? null
                    : () async {
                        setState(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          final saved = await widget.editManually!(
                            Set.of(selected),
                          );
                          if (mounted && saved != null)
                            setState(() => selected = Set.of(saved));
                        } catch (_) {
                          if (mounted) setState(() => error = '保存未完成，请重试。');
                        } finally {
                          if (mounted) setState(() => saving = false);
                        }
                      },
              ),
          ],
          systemOverlayStyle: demo.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: .84),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: .4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.prompt,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('engine-app-search'),
                        controller: search,
                        onChanged: (_) => filterChanged(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: '搜索应用名称或拼音',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除搜索',
                                  onPressed: () => filterChanged(search.clear),
                                  icon: const Icon(Icons.close),
                                ),
                          filled: true,
                          fillColor: colors.onSurface.withValues(alpha: .045),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            label: Text('全部 ${apps.length}'),
                            selected: !selectedOnly,
                            showCheckmark: false,
                            shape: const StadiumBorder(),
                            side: BorderSide.none,
                            selectedColor: colors.primary.withValues(
                              alpha: .15,
                            ),
                            onSelected: (_) =>
                                filterChanged(() => selectedOnly = false),
                          ),
                          ChoiceChip(
                            label: Text('已选 ${selected.length}'),
                            selected: selectedOnly,
                            showCheckmark: false,
                            shape: const StadiumBorder(),
                            side: BorderSide.none,
                            selectedColor: colors.primary.withValues(
                              alpha: .15,
                            ),
                            onSelected: (_) =>
                                filterChanged(() => selectedOnly = true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.sort_by_alpha, size: 16, color: backdropInk),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '长按左侧刻度，滑动定位字母',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: backdropInk,
                        ),
                      ),
                    ),
                    Text(
                      '${filtered.length} 个',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: backdropInk,
                      ),
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
                    style: TextStyle(
                      color: demo.dark ? colors.errorContainer : colors.error,
                    ),
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
                          style: TextStyle(color: backdropInk),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) => Stack(
                          children: [
                            ListView.builder(
                              key: const ValueKey('engine-app-results'),
                              controller: scroll,
                              padding: EdgeInsets.fromLTRB(
                                40,
                                8,
                                8,
                                math.max(
                                  24,
                                  constraints.maxHeight -
                                      rowHeight -
                                      groupHeight,
                                ),
                              ),
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: rows.length,
                              itemExtentBuilder: (index, _) =>
                                  rows[index] is String
                                  ? groupHeight
                                  : rowHeight,
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                if (row is String) {
                                  return Padding(
                                    key: ValueKey('engine-app-letter-$row'),
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      4,
                                      12,
                                      4,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          row,
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                                color: demo.dark
                                                    ? colors.primaryContainer
                                                    : colors.primary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Divider(
                                            color: colors.outlineVariant
                                                .withValues(alpha: .35),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                final app = row as EngineSelectableApp;
                                final allowed = selected.contains(app.package);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                    horizontal: 4,
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: allowed
                                          ? colors.primaryContainer.withValues(
                                              alpha: .8,
                                            )
                                          : colors.surface.withValues(
                                              alpha: .8,
                                            ),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: allowed
                                            ? colors.primary.withValues(
                                                alpha: .22,
                                              )
                                            : colors.outlineVariant.withValues(
                                                alpha: .24,
                                              ),
                                      ),
                                    ),
                                    child: GestureDetector(
                                      onLongPress: () => showAppInfo(app),
                                      child: CheckboxListTile(
                                        key: ValueKey(
                                          'engine-app-${app.package}',
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 16,
                                            ),
                                        secondary: Container(
                                          width: 40,
                                          height: 40,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: colors.primary.withValues(
                                              alpha: .1,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          child: Text(
                                            app.name.isEmpty
                                                ? '?'
                                                : app.name.characters.first,
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w600,
                                              color: colors.primary,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          app.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        checkboxShape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        value: allowed,
                                        onChanged: saving
                                            ? null
                                            : (v) => toggle(app, v == true),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            if (groupOffsets.length > 1)
                              Positioned(
                                left: 2,
                                top: 12,
                                bottom: 12,
                                width: 34,
                                child: ValueListenableBuilder<String>(
                                  valueListenable: currentLetter,
                                  builder: (context, letter, _) => AppAlphabetRuler(
                                    letters: groupOffsets.keys.toList(),
                                    currentLetter: letter,
                                    onBrowseStart: (details) {
                                      browsing?.cancel();
                                      browsing = scroll.position.drag(
                                        details,
                                        () => browsing = null,
                                      );
                                    },
                                    onBrowseUpdate: (details) =>
                                        browsing?.update(details),
                                    onBrowseEnd: (details) {
                                      browsing?.end(details);
                                      browsing = null;
                                    },
                                    onBrowseCancel: () {
                                      browsing?.cancel();
                                      browsing = null;
                                    },
                                    onJump: (letter) {
                                      if (scroll.hasClients) {
                                        // A lazy variable-extent list can still have
                                        // an estimated max extent before this group
                                        // is built. Its exact prefix offset is known.
                                        scroll.jumpTo(groupOffsets[letter]!);
                                      }
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
