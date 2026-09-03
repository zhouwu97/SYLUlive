import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/course_evaluation.dart';
import '../providers/course_subject_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'teacher_detail_screen.dart';

/// 学科榜详情页。
///
/// 接收服务端标准学科 ID 与名称，按 ID 加载该学科的已审核教师；
/// 不再用教师文本分组，也不通过包含关系合并 A1/A2。
/// 教师详情评分返回后按 ID 刷新本页统计。
class SubjectRankingDetailScreen extends StatefulWidget {
  final int subjectId;
  final String subjectName;

  const SubjectRankingDetailScreen({
    super.key,
    required this.subjectId,
    required this.subjectName,
  });

  @override
  State<SubjectRankingDetailScreen> createState() =>
      _SubjectRankingDetailScreenState();
}

class _SubjectRankingDetailScreenState
    extends State<SubjectRankingDetailScreen> {
  CourseSubjectDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetail());
  }

  Future<void> _loadDetail() async {
    final provider = context.read<CourseSubjectProvider>();
    // 评分返回后必须拿最新统计，这里始终强制刷新。
    final detail =
        await provider.loadSubjectDetail(widget.subjectId, force: true);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _loading = false;
      _error = detail == null ? '学科详情加载失败，请稍后重试' : null;
    });
  }

  Future<void> _openTeacherDetail(CourseSubjectTeacher teacher) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherDetailScreen(
          teacherId: teacher.id,
          teacherName: teacher.name,
        ),
      ),
    );
    if (changed != true || !mounted) return;
    _changed = true;
    // 评分返回后按学科 ID 重新加载教师与统计。
    await _loadDetail();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final accent = RankingTokens.teacherAccent(isDark);
    final detail = _detail;
    final teachers = detail?.teachers ?? const <CourseSubjectTeacher>[];

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: RankingTokens.pageBg(isDark),
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          title: Text(
            widget.subjectName,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          backgroundColor: RankingTokens.pageBg(isDark),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          titleTextStyle: TextStyle(
            color: RankingTokens.titleColor(isDark),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
          iconTheme: IconThemeData(color: RankingTokens.titleColor(isDark)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          style: TextStyle(
                            color: RankingTokens.subColor(isDark),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _loadDetail,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadDetail,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        // Header card
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: RankingTokens.cardDecoration(isDark),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color:
                                          RankingTokens.teacherAccentSoft(isDark),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Icon(
                                      Icons.auto_stories_outlined,
                                      color: accent,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.subjectName,
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                            color:
                                                RankingTokens.titleColor(isDark),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '按教师评分排序，点击可查看详情与评价',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                RankingTokens.subColor(isDark),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  _buildMetric(
                                    isDark,
                                    '教师数',
                                    '${teachers.length}',
                                    Icons.groups_2_outlined,
                                    accent,
                                  ),
                                  const SizedBox(width: 10),
                                  _buildMetric(
                                    isDark,
                                    '学科均分',
                                    (detail?.averageStar ?? 0)
                                        .toStringAsFixed(1),
                                    Icons.star_rounded,
                                    accent,
                                  ),
                                  const SizedBox(width: 10),
                                  _buildMetric(
                                    isDark,
                                    '总评价数',
                                    '${detail?.ratingCount ?? 0}',
                                    Icons.rate_review_outlined,
                                    accent,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (teachers.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 48),
                            child: Center(
                              child: Text(
                                '该学科暂无已审核教师',
                                style: TextStyle(
                                  color: RankingTokens.subColor(isDark),
                                ),
                              ),
                            ),
                          )
                        else
                          ...teachers.asMap().entries.map(
                                (entry) {
                                  final index = entry.key;
                                  final teacher = entry.value;
                                  final rankColor = _rankColor(index);
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      bottom: RankingTokens.cardGap,
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(
                                          RankingTokens.cardRadius,
                                        ),
                                        onTap: () =>
                                            _openTeacherDetail(teacher),
                                        child: Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration:
                                              RankingTokens.cardDecoration(
                                            isDark,
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 40,
                                                height: 40,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color: rankColor
                                                      .withValues(alpha: 0.12),
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Text(
                                                  '#${index + 1}',
                                                  style: TextStyle(
                                                    color: rankColor,
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      teacher.name,
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: RankingTokens
                                                            .titleColor(isDark),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      '${teacher.averageStar.toStringAsFixed(1)} 分 · ${teacher.ratingCount} 条评价',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: RankingTokens
                                                            .subColor(isDark),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Icon(
                                                Icons
                                                    .chevron_right_rounded,
                                                size: 20,
                                                color: RankingTokens.subColor(
                                                  isDark,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildMetric(
    bool isDark,
    String label,
    String value,
    IconData icon,
    Color accent,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: accent),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: RankingTokens.subColor(isDark),
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: RankingTokens.titleColor(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _rankColor(int index) {
    if (index == 0) return RankingTokens.rankGold;
    if (index == 1) return RankingTokens.rankSilver;
    if (index == 2) return RankingTokens.rankBronze;
    return const Color(0xFF9CA3AF);
  }
}
