import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/teacher.dart';
import '../providers/major_provider.dart';
import '../providers/teacher_provider.dart';
import '../widgets/glass_container.dart';
import 'major_detail_screen.dart';
import 'subject_ranking_detail_screen.dart';

class TeacherRateScreen extends StatefulWidget {
  const TeacherRateScreen({super.key});

  @override
  State<TeacherRateScreen> createState() => _TeacherRateScreenState();
}

class _TeacherRateScreenState extends State<TeacherRateScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  bool _showDisclaimer = true;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      context.read<TeacherProvider>().loadTeachers(query: _currentQuery),
      context.read<MajorProvider>().loadMajors(),
    ]);
  }

  String? get _currentQuery {
    final query = _searchCtrl.text.trim();
    return query.isEmpty ? null : query;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Column(
              children: [
                if (_showDisclaimer) _buildDisclaimer(isDark),
                _buildSearchBar(isDark),
                _buildSegmentedControl(isDark),
                Expanded(
                  child: _tabCtrl.index == 0
                      ? _buildSubjectList(isDark)
                      : _buildMajorList(isDark),
                ),
              ],
            ),
            Positioned(
              right: 20,
              bottom: 20,
              child: _buildFAB(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentedControl(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildSegmentItem(0, '学科榜', isDark),
            ),
            Expanded(
              child: _buildSegmentItem(1, '专业榜', isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentItem(int index, String label, bool isDark) {
    final isSelected = _tabCtrl.index == index;
    return GestureDetector(
      onTap: () {
        _tabCtrl.animateTo(index);
        setState(() {});
      },
      child: Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? const Color(0xFF6D5EF9).withValues(alpha: 0.15)
              : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected
                ? const Color(0xFF6D5EF9)
                : (isDark ? Colors.white60 : Colors.black54),
          ),
        ),
      ),
    );
  }

  Widget _buildFAB(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe > 0 ? bottomSafe : 0),
      child: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: const Color(0xFF16A34A),
        elevation: 4,
        shape: const CircleBorder(),
        child: const Icon(Icons.add, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildDisclaimer(bool isDark) => GlassContainer(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(12),
        borderRadius: 14,
        blur: 12,
        opacity: 0.18,
        backgroundColor:
            isDark ? const Color(0xA3182033) : const Color(0xCCEAF1FF),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: isDark ? Colors.blue[300] : Colors.blue[700],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '教师榜已按学科聚合。添加教师时请填写完整课程名称，例如“数据结构”“高等数学A1”，避免同一学科被拆散。',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey[300] : Colors.grey[700],
                  height: 1.45,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _showDisclaimer = false),
              child: const Icon(Icons.close, size: 16, color: Colors.grey),
            ),
          ],
        ),
      );

  Widget _buildSearchBar(bool isDark) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: GlassContainer(
          borderRadius: 50,
          blur: 12,
          opacity: 0.18,
          backgroundColor:
              isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
          borderColor: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.72),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: _tabCtrl.index == 0 ? '搜索学科或教师...' : '搜索专业...',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (value) {
              if (_tabCtrl.index == 0) {
                context
                    .read<TeacherProvider>()
                    .loadTeachers(query: value.trim().isEmpty ? null : value);
              } else {
                setState(() {});
              }
            },
          ),
        ),
      );

  Widget _buildSubjectList(bool isDark) =>
      Consumer<TeacherProvider>(builder: (_, provider, __) {
        if (provider.isLoading && provider.teachers.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final groups = _buildSubjectGroups(provider.teachers, _currentQuery);
        if (groups.isEmpty) {
          return Center(
            child: Text(
              '暂无学科数据',
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            await context
                .read<TeacherProvider>()
                .loadTeachers(query: _currentQuery);
          },
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            itemCount: groups.length,
            itemBuilder: (_, index) {
              final group = groups[index];
              final topTeachers =
                  group.teachers.take(3).map((t) => t.name).join(' · ');
              return _buildLeaderboardCard(
                isDark: isDark,
                rank: index + 1,
                title: group.subject,
                subtitle: topTeachers.isEmpty ? '暂无教师' : '代表教师 · $topTeachers',
                average: group.averageStar,
                count: group.ratingCount,
                extraLabel: '${group.teachers.length} 位教师',
                icon: Icons.auto_stories_outlined,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SubjectRankingDetailScreen(
                      subjectName: group.subject,
                      teachers: group.teachers,
                    ),
                  ),
                ).then((changed) async {
                  if (changed != true || !mounted) return;
                  await context
                      .read<TeacherProvider>()
                      .loadTeachers(query: _currentQuery);
                }),
              );
            },
          ),
        );
      });

  Widget _buildMajorList(bool isDark) =>
      Consumer<MajorProvider>(builder: (_, provider, __) {
        final query = _currentQuery?.toLowerCase();
        final majors = query == null
            ? provider.majors
            : provider.majors
                .where((m) => m.name.toLowerCase().contains(query))
                .toList();

        if (provider.isLoading && provider.majors.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (majors.isEmpty) {
          return Center(
            child: Text(
              '暂无专业',
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.grey[600],
              ),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () => context.read<MajorProvider>().loadMajors(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            itemCount: majors.length,
            itemBuilder: (_, index) {
              final major = majors[index];
              return _buildLeaderboardCard(
                isDark: isDark,
                rank: index + 1,
                title: major.name,
                subtitle: major.level,
                average: major.averageStar,
                count: major.ratingCount,
                extraLabel: '专业评分',
                icon: Icons.school_outlined,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MajorDetailScreen(
                      majorId: major.id,
                      majorName: major.name,
                    ),
                  ),
                ).then((_) {
                  if (!mounted) return;
                  context.read<MajorProvider>().loadMajors();
                }),
              );
            },
          ),
        );
      });

  Widget _buildLeaderboardCard({
    required bool isDark,
    required int rank,
    required String title,
    required String subtitle,
    required double average,
    required int count,
    required String extraLabel,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final accent = _rankColor(rank - 1);
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 20,
      blur: 12,
      opacity: 0.18,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.72),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: 18),
                  const SizedBox(height: 2),
                  Text(
                    '#$rank',
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildMetricChip(
                        isDark,
                        Icons.star_rounded,
                        average.toStringAsFixed(1),
                      ),
                      _buildMetricChip(
                        isDark,
                        Icons.rate_review_outlined,
                        '$count 条评价',
                      ),
                      _buildMetricChip(
                        isDark,
                        Icons.layers_outlined,
                        extraLabel,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricChip(bool isDark, IconData icon, String text) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      borderRadius: 999,
      blur: 8,
      opacity: 0.14,
      backgroundColor: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.68),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.white.withValues(alpha: 0.52),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF6D5EF9)),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }

  List<_SubjectGroup> _buildSubjectGroups(
      List<Teacher> teachers, String? query) {
    final keyword = query?.trim().toLowerCase();
    final map = <String, List<Teacher>>{};

    for (final teacher in teachers) {
      final subject =
          teacher.course.trim().isEmpty ? '未分类课程' : teacher.course.trim();
      final hit = keyword == null ||
          subject.toLowerCase().contains(keyword) ||
          teacher.name.toLowerCase().contains(keyword);
      if (!hit) continue;
      map.putIfAbsent(subject, () => <Teacher>[]).add(teacher);
    }

    final groups = map.entries.map((entry) {
      final items = [...entry.value]..sort((a, b) {
          final compare = b.averageStar.compareTo(a.averageStar);
          if (compare != 0) return compare;
          return b.ratingCount.compareTo(a.ratingCount);
        });
      return _SubjectGroup(entry.key, items);
    }).toList();

    groups.sort((a, b) {
      final compare = b.averageStar.compareTo(a.averageStar);
      if (compare != 0) return compare;
      final countCompare = b.ratingCount.compareTo(a.ratingCount);
      if (countCompare != 0) return countCompare;
      return a.subject.compareTo(b.subject);
    });
    return groups;
  }

  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final courseCtrl = TextEditingController();
    final levelCtrl = TextEditingController(text: '本科');
    final isTeacher = _tabCtrl.index == 0;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isTeacher ? '添加教师' : '添加专业'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: isTeacher ? '教师姓名' : '专业名',
              ),
            ),
            const SizedBox(height: 8),
            if (isTeacher)
              TextField(
                controller: courseCtrl,
                decoration: const InputDecoration(
                  labelText: '课程名称',
                  helperText: '请填写完整课程名称，学科榜会按这里的文字聚合',
                ),
              )
            else
              DropdownButtonFormField(
                initialValue: '本科',
                items: const [
                  DropdownMenuItem(value: '本科', child: Text('本科')),
                  DropdownMenuItem(value: '研究生', child: Text('研究生')),
                ],
                onChanged: (v) => levelCtrl.text = v!,
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final course = courseCtrl.text.trim();
              if (name.isEmpty) return;
              if (isTeacher && course.length < 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写完整课程名称')),
                );
                return;
              }
              Navigator.pop(ctx);
              if (isTeacher) {
                await context.read<TeacherProvider>().addTeacher(name, course);
                if (!mounted) return;
                await context
                    .read<TeacherProvider>()
                    .loadTeachers(query: _currentQuery);
              } else {
                await context
                    .read<MajorProvider>()
                    .addMajor(name, levelCtrl.text);
                if (!mounted) return;
                await context.read<MajorProvider>().loadMajors();
              }
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );
  }

  Color _rankColor(int index) {
    if (index == 0) return const Color(0xFFF59E0B);
    if (index == 1) return const Color(0xFF6366F1);
    if (index == 2) return const Color(0xFF10B981);
    return const Color(0xFF8B5CF6);
  }
}

class _SubjectGroup {
  final String subject;
  final List<Teacher> teachers;

  const _SubjectGroup(this.subject, this.teachers);

  int get ratingCount =>
      teachers.fold<int>(0, (sum, teacher) => sum + teacher.ratingCount);

  double get averageStar {
    if (teachers.isEmpty) return 0;
    if (ratingCount == 0) {
      final sum = teachers.fold<double>(
        0,
        (value, teacher) => value + teacher.averageStar,
      );
      return sum / teachers.length;
    }
    final total = teachers.fold<double>(
      0,
      (value, teacher) => value + teacher.averageStar * teacher.ratingCount,
    );
    return total / ratingCount;
  }
}
