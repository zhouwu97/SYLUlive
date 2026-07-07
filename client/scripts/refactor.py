import re

path = 'client/lib/screens/water_category_feed_screen.dart'
with open(path, 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Replace state variables
code = re.sub(
    r"String _currentSort = 'all';\s*int\? _selectedTagId;",
    r"String _selectedFilterKey = 'mode:recommend';",
    code
)

# 2. Add _resolveFilterKey
code = re.sub(
    r"(String _defaultSortFor\(WaterSection section\) =>\s*defaultSortForSection\(section\);)",
    r"\1\n\n  MapEntry<String, int?> _resolveFilterKey(String key) {\n    if (key == 'mode:latest') return const MapEntry('time', null);\n    if (key == 'mode:featured') return const MapEntry('featured', null);\n    if (key.startsWith('tag:')) return MapEntry('all', int.tryParse(key.substring(4)));\n    return const MapEntry('all', null);\n  }",
    code
)

# 3. Update initState / _resolveSection
code = re.sub(
    r"_currentSort = _defaultSortFor\(widget\.section \?\? _sectionFromCategory\(\)\);",
    r"final ds = _defaultSortFor(widget.section ?? _sectionFromCategory());\n    if (ds == 'time') _selectedFilterKey = 'mode:latest';\n    else if (ds == 'featured') _selectedFilterKey = 'mode:featured';\n    else _selectedFilterKey = 'mode:recommend';",
    code
)

code = re.sub(
    r"if \(updateSortFromFreshSection && !_sortTouched\) {\s*_currentSort = _defaultSortFor\(fresh\);\s*}\s*if \(_selectedTagId != null &&\s*!fresh\.enabledTags\.any\(\(tag\) => tag\.id == _selectedTagId\)\) {\s*_selectedTagId = null;\s*}",
    r"""if (updateSortFromFreshSection && !_sortTouched) {
        final ds = _defaultSortFor(fresh);
        if (ds == 'time') _selectedFilterKey = 'mode:latest';
        else if (ds == 'featured') _selectedFilterKey = 'mode:featured';
        else _selectedFilterKey = 'mode:recommend';
      }
      if (_selectedFilterKey.startsWith('tag:')) {
        final tid = int.tryParse(_selectedFilterKey.substring(4));
        if (tid != null && !fresh.enabledTags.any((t) => t.id == tid)) {
          _selectedFilterKey = 'mode:recommend';
        }
      }""",
    code
)

# update ManageScreen return logic
code = re.sub(
    r"if \(_selectedTagId != null &&\s*!fresh\.enabledTags\.any\(\(tag\) => tag\.id == _selectedTagId\)\) {\s*_selectedTagId = null;\s*}",
    r"""if (_selectedFilterKey.startsWith('tag:')) {
            final tid = int.tryParse(_selectedFilterKey.substring(4));
            if (tid != null && !fresh.enabledTags.any((t) => t.id == tid)) {
              _selectedFilterKey = 'mode:recommend';
            }
          }""",
    code
)


# 4. Update _load
code = re.sub(
    r"final sort = _currentSort;\s*final tagId = _selectedTagId;",
    r"final st = _resolveFilterKey(_selectedFilterKey);\n    final sort = st.key;\n    final tagId = st.value;",
    code
)

# 5. Update _refresh
code = re.sub(
    r"sort: _currentSort,\s*type: section\.slug,\s*tagId: _selectedTagId,",
    r"sort: _resolveFilterKey(_selectedFilterKey).key,\n              type: section.slug,\n              tagId: _resolveFilterKey(_selectedFilterKey).value,",
    code
)

# 6. Update _loadMore
code = re.sub(
    r"sort: _currentSort,\s*type: section\.slug,\s*tagId: _selectedTagId,",
    r"sort: _resolveFilterKey(_selectedFilterKey).key,\n          type: section.slug,\n          tagId: _resolveFilterKey(_selectedFilterKey).value,",
    code
)

# 7. Update _changeSort and _changeTag into _changeFilter
code = re.sub(
    r"Future<void> _changeSort\(String sort\) async \{\s*if \(sort == _currentSort\) return;\s*setState\(\(\) \{\s*_currentSort = sort;\s*_sortTouched = true;\s*\}\);\s*if \(_sheetScrollController\?\.hasClients == true\) \{\s*_sheetScrollController!\.animateTo\(\s*0,\s*duration: const Duration\(milliseconds: 180\),\s*curve: Curves\.easeOut,\s*\);\s*\}\s*await _load\(\);\s*\}\s*Future<void> _changeTag\(int\? tagId\) async \{\s*final newTagId = \(tagId == _selectedTagId\) \? null : tagId;\s*if \(newTagId == _selectedTagId\) return;\s*setState\(\(\) => _selectedTagId = newTagId\);\s*await _load\(\);\s*\}",
    r"""Future<void> _changeFilter(String key) async {
    if (key == _selectedFilterKey) return;
    setState(() {
      _selectedFilterKey = key;
      _sortTouched = true;
    });
    if (_sheetScrollController?.hasClients == true) {
      _sheetScrollController!.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    await _load();
  }""",
    code
)


# 8. Replace PageStorageKey
code = re.sub(
    r"PageStorageKey\('water_category_\$\{section\.slug\}_\$\{_selectedTagId \?\? 'all'\}'\)",
    r"PageStorageKey('water_category_${section.slug}_${_selectedFilterKey}')",
    code
)

# 9. Replace SectionFilterHeader usage
code = re.sub(
    r"SectionFilterHeader\(\s*sortOptions: const \[\],\s*currentSort: _currentSort,\s*section: section,\s*selectedTagId: _selectedTagId,\s*accentColor: accentColor,\s*isDark: isDark,\s*onSortChanged: _changeSort,\s*onTagChanged: _changeTag,\s*\)",
    r"""SectionFilterHeader(
            currentFilterKey: _selectedFilterKey,
            section: section,
            accentColor: accentColor,
            isDark: isDark,
            onFilterChanged: _changeFilter,
          )""",
    code
)

# 10. Replace RefreshIndicator onRefresh call in the body for _openPost
code = re.sub(
    r"await context\.read<PostProvider>\(\)\.refresh\(\s*boardId: 1,\s*sort: _currentSort,\s*type: section\.slug,\s*tagId: _selectedTagId,\s*\);",
    r"""await context.read<PostProvider>().refresh(
                boardId: 1,
                sort: _resolveFilterKey(_selectedFilterKey).key,
                type: section.slug,
                tagId: _resolveFilterKey(_selectedFilterKey).value,
              );""",
    code
)


with open(path, 'w', encoding='utf-8') as f:
    f.write(code)
print("Done refactoring water_category_feed_screen.dart")
