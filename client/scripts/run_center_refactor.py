import sys
import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

if "import 'competition_official_event_editor_screen.dart';" not in content:
    content = content.replace("import 'competition_admin_import_screen.dart';", "import 'competition_admin_import_screen.dart';\nimport 'competition_official_event_editor_screen.dart';")

# 1. State variables
if 'String _adminEventStatus = ' not in content:
    content = content.replace('int _currentTab = 0;', 'int _currentTab = 0;\n  String _adminEventStatus = \'all\';')

# 2. _loadEvents logic
# Find:
#     final res = await _dio.get(
#       '/competitions/events',
#       queryParameters: _queryParams(),
#     );
load_pattern = r"final res = await _dio\.get\(\s*'/competitions/events',\s*queryParameters: _queryParams\(\),\s*\);"
new_load = """
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.user;
    final isAdmin = user?.isAdmin == true;
    
    final endpoint = isAdmin ? '/admin/competitions/events' : '/competitions/events';
    final params = _queryParams();
    if (isAdmin && _adminEventStatus != 'all') {
      params['status'] = _adminEventStatus;
    }
    
    final res = await _dio.get(
      endpoint,
      queryParameters: params,
    );
"""
content = re.sub(load_pattern, new_load, content)

# 3. _openAdminImport
# Find:
#   void _openAdminImport() {
#     Navigator.push(
#       context,
#       MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
#     );
#   }
import_pattern = r"void _openAdminImport\(\) \{[\s\S]*?\}"
new_import = """
  Future<void> _openAdminImport() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
    if (result == true) {
      _load();
    }
  }

  Future<void> _openAdminManualCreate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionOfficialEventEditorScreen()),
    );
    if (result == true) {
      _load();
    }
  }
"""
content = re.sub(import_pattern, new_import, content)

# 4. Empty State
empty_pattern = r"CompetitionEmptyState\([\s\S]*?primaryText:[\s\S]*?\),"
new_empty = """
CompetitionEmptyState(
  title: user?.isAdmin == true
      ? '官方比赛库还没有内容'
      : '暂时没有公开比赛',
  message: user?.isAdmin == true
      ? '公开比赛会展示在这里，供所有用户浏览和加入计划。'
      : '管理员补充公开比赛后，会显示在这里。你也可以先查看自己的竞赛计划。',
  primaryText: user?.isAdmin == true ? 'AI导入公开比赛' : '查看我的计划',
  secondaryText: user?.isAdmin == true ? '手动新建公开比赛' : '刷新',
  onPrimaryTap: () {
    if (user?.isAdmin == true) {
      _openAdminImport();
    } else {
      // scroll to top and switch tab or show plan
      setState(() {
        _currentTab = 1;
      });
      _pageController.animateToPage(
        1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  },
  onSecondaryTap: () {
    if (user?.isAdmin == true) {
      _openAdminManualCreate();
    } else {
      _load();
    }
  },
),
"""
content = re.sub(empty_pattern, new_empty, content)

# 5. Header for Events list
# Find sliver list of events
sliver_list_start = r"SliverList\(\s*delegate: SliverChildBuilderDelegate\(\s*\(context, index\) \{\s*final event = _events\[index\];"

admin_filters = """
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.user;
    final isAdmin = user?.isAdmin == true;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '官方比赛库',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1F2328),
                ),
              ),
              const Spacer(),
              if (isAdmin)
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _openAdminManualCreate,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('新建', style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                    TextButton.icon(
                      onPressed: _openAdminImport,
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('AI导入', style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                  ],
                ),
            ],
          ),
          if (isAdmin) ...[
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _adminEventStatus == 'all',
                    onSelected: (v) {
                      if (v) {
                        setState(() => _adminEventStatus = 'all');
                        _load(refresh: true);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('已发布'),
                    selected: _adminEventStatus == 'published',
                    onSelected: (v) {
                      if (v) {
                        setState(() => _adminEventStatus = 'published');
                        _load(refresh: true);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('草稿'),
                    selected: _adminEventStatus == 'draft',
                    onSelected: (v) {
                      if (v) {
                        setState(() => _adminEventStatus = 'draft');
                        _load(refresh: true);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
"""

# Wait, the easiest way to inject header is replacing the first item of the list if it doesn't already have one,
# but it's cleaner to inject a SliverToBoxAdapter before the SliverList.
# Let's find `if (!_isInitialLoading && _events.isNotEmpty) ...[`
# We can inject `SliverToBoxAdapter` right before `SliverList`.
# Wait, actually there are `SliverPadding` and stuff.
# Let's look for `SliverList` directly.

with open('e:/AI/xynewui/client/scripts/refactor_center.py', 'w', encoding='utf-8') as f:
    f.write('''import sys
import re

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

if "import 'competition_official_event_editor_screen.dart';" not in content:
    content = content.replace("import 'competition_admin_import_screen.dart';", "import 'competition_admin_import_screen.dart';\\nimport 'competition_official_event_editor_screen.dart';")

if 'String _adminEventStatus =' not in content:
    content = content.replace('int _currentTab = 0;', 'int _currentTab = 0;\\n  String _adminEventStatus = \\'all\\';')

load_pattern = r"final res = await _dio\\.get\\(\\s*'/competitions/events',\\s*queryParameters: _queryParams\\(\\),\\s*\\);"
new_load = """
    final authProvider = context.read<AuthProvider>();
    final user = authProvider.user;
    final isAdmin = user?.isAdmin == true;
    
    final endpoint = isAdmin ? '/admin/competitions/events' : '/competitions/events';
    final params = _queryParams();
    if (isAdmin && _adminEventStatus != 'all') {
      params['status'] = _adminEventStatus;
    }
    
    final res = await _dio.get(
      endpoint,
      queryParameters: params,
    );
"""
content = re.sub(load_pattern, new_load, content)

import_pattern = r"void _openAdminImport\\(\\) \\{[\\s\\S]*?\\}"
new_import = """
  Future<void> _openAdminImport() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminImportScreen()),
    );
    if (result == true) {
      _load();
    }
  }

  Future<void> _openAdminManualCreate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionOfficialEventEditorScreen()),
    );
    if (result == true) {
      _load();
    }
  }
"""
content = re.sub(import_pattern, new_import, content)

empty_pattern = r"CompetitionEmptyState\\([\\s\\S]*?primaryText:[\\s\\S]*?\\),"
new_empty = """
CompetitionEmptyState(
  title: user?.isAdmin == true
      ? '官方比赛库还没有内容'
      : '暂时没有公开比赛',
  message: user?.isAdmin == true
      ? '公开比赛会展示在这里，供所有用户浏览和加入计划。'
      : '管理员补充公开比赛后，会显示在这里。你也可以先查看自己的竞赛计划。',
  primaryText: user?.isAdmin == true ? 'AI导入公开比赛' : '查看我的计划',
  secondaryText: user?.isAdmin == true ? '手动新建公开比赛' : '刷新',
  onPrimaryTap: () {
    if (user?.isAdmin == true) {
      _openAdminImport();
    } else {
      setState(() {
        _currentTab = 1;
      });
      _pageController.animateToPage(
        1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  },
  onSecondaryTap: () {
    if (user?.isAdmin == true) {
      _openAdminManualCreate();
    } else {
      _load();
    }
  },
),
"""
content = re.sub(empty_pattern, new_empty, content)

# inject header for events
header_code = """
          if (!_isInitialLoading && _events.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '官方比赛库',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF1F2328),
                          ),
                        ),
                        const Spacer(),
                        if (user?.isAdmin == true)
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: _openAdminManualCreate,
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('新建', style: TextStyle(fontSize: 13)),
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                              ),
                              TextButton.icon(
                                onPressed: _openAdminImport,
                                icon: const Icon(Icons.auto_awesome, size: 16),
                                label: const Text('AI导入', style: TextStyle(fontSize: 13)),
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (user?.isAdmin == true) ...[
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('全部'),
                              selected: _adminEventStatus == 'all',
                              onSelected: (v) {
                                if (v) {
                                  setState(() => _adminEventStatus = 'all');
                                  _load(refresh: true);
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('已发布'),
                              selected: _adminEventStatus == 'published',
                              onSelected: (v) {
                                if (v) {
                                  setState(() => _adminEventStatus = 'published');
                                  _load(refresh: true);
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('草稿'),
                              selected: _adminEventStatus == 'draft',
                              onSelected: (v) {
                                if (v) {
                                  setState(() => _adminEventStatus = 'draft');
                                  _load(refresh: true);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
"""
# find `if (!_isInitialLoading && _events.isNotEmpty) ...[`
content = content.replace("if (!_isInitialLoading && _events.isNotEmpty) ...[", header_code + "\\n          if (!_isInitialLoading && _events.isNotEmpty) ...[")

with open('e:/AI/xynewui/client/lib/screens/competition/competition_center_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
''')
