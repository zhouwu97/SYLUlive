import 'package:flutter/material.dart';

import '../features/physical/physical_percentile_models.dart';
import '../features/physical/physical_percentile_service.dart';

class PhysicalPercentileReportScreen extends StatefulWidget {
  final List<PhysicalRawScore> scores;
  final PhysicalGender gender;
  final PhysicalPercentileService? serviceOverride;

  const PhysicalPercentileReportScreen({
    super.key,
    required this.scores,
    required this.gender,
    this.serviceOverride,
  });

  @override
  State<PhysicalPercentileReportScreen> createState() =>
      _PhysicalPercentileReportScreenState();
}

class _PhysicalPercentileReportScreenState
    extends State<PhysicalPercentileReportScreen> {
  PhysicalCompareGroup _group = PhysicalCompareGroup.sameGender;
  late final Future<PhysicalPercentileService> _serviceFuture;

  @override
  void initState() {
    super.initState();
    _serviceFuture = widget.serviceOverride != null
        ? Future.value(widget.serviceOverride)
        : PhysicalPercentileService.loadFromAsset();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('超越了多少大学生'),
        backgroundColor:
            isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        elevation: 0,
      ),
      body: FutureBuilder<PhysicalPercentileService>(
        future: _serviceFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return _buildErrorState(isDark);
          }

          final studentResults =
              PhysicalPercentileService.normalizeStudentResults(widget.scores);
          if (studentResults.isEmpty) {
            return _buildEmptyState(isDark);
          }

          final service = snapshot.data!;
          final effectiveGender = widget.gender == PhysicalGender.unknown
              ? PhysicalPercentileService.inferGenderFromMetricIds(
                  studentResults.map((result) => result.metricId),
                )
              : widget.gender;
          final report = service.buildSnapshot(
            studentResults: studentResults,
            group: _group,
            gender: effectiveGender,
          );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(report, isDark),
                  const SizedBox(height: 14),
                  _buildGroupSelector(isDark),
                  const SizedBox(height: 18),
                  _buildHighlights(report, isDark),
                  const SizedBox(height: 18),
                  _buildSectionTitle('项目列表', isDark),
                  const SizedBox(height: 10),
                  _buildMetricList(report.sportMetrics, isDark),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard(PhysicalReportSnapshot report, bool isDark) {
    final groupText = PhysicalPercentileService.groupLabel(_group);
    return _SurfaceCard(
      isDark: isDark,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.insights_rounded,
                  color: Color(0xFF6366F1),
                  size: 23,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '你的运动表现超过了$groupText ${report.sportAveragePercentile}% 的大学生',
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF1F2430),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: report.sportAveragePercentile / 100,
              minHeight: 8,
              backgroundColor:
                  isDark ? Colors.white12 : const Color(0xFFE9ECF3),
              color: const Color(0xFF6366F1),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '娱乐参考结果，按匿名样本分布计算，不代表官方排名。',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : const Color(0xFF737B8C),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupSelector(bool isDark) {
    const groups = [
      PhysicalCompareGroup.sameGender,
      PhysicalCompareGroup.all,
      PhysicalCompareGroup.male,
      PhysicalCompareGroup.female,
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFE8EBF2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: groups.map((group) {
          final selected = group == _group;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => setState(() => _group = group),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? (isDark ? const Color(0xFF2B3140) : Colors.white)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: selected && !isDark
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  PhysicalPercentileService.groupLabel(group),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? const Color(0xFF6366F1)
                        : (isDark ? Colors.white70 : const Color(0xFF596170)),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildHighlights(PhysicalReportSnapshot report, bool isDark) {
    if (report.highlights.isEmpty) {
      return _SurfaceCard(
        isDark: isDark,
        child: Text(
          '暂无可展示亮点',
          style: TextStyle(
              color: isDark ? Colors.white60 : const Color(0xFF737B8C)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle('亮点项目', isDark),
        const SizedBox(height: 10),
        _SurfaceCard(
          isDark: isDark,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            children: report.highlights
                .map((metric) => _HighlightRow(metric: metric, isDark: isDark))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String text, bool isDark) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w800,
        color: isDark ? Colors.white : const Color(0xFF20232A),
      ),
    );
  }

  Widget _buildMetricList(List<PhysicalReportMetric> metrics, bool isDark) {
    if (metrics.isEmpty) {
      return _SurfaceCard(
        isDark: isDark,
        child: Text(
          '暂无可比项目',
          style: TextStyle(
              color: isDark ? Colors.white60 : const Color(0xFF737B8C)),
        ),
      );
    }

    return _SurfaceCard(
      isDark: isDark,
      padding: EdgeInsets.zero,
      child: Column(
        children: metrics.asMap().entries.map((entry) {
          return Column(
            children: [
              _MetricRow(metric: entry.value, isDark: isDark),
              if (entry.key < metrics.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark ? Colors.white10 : const Color(0xFFEEF0F4),
                  indent: 16,
                  endIndent: 16,
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 46,
              color: isDark ? Colors.white38 : const Color(0xFF9AA1AF),
            ),
            const SizedBox(height: 14),
            Text(
              '匿名统计数据暂时加载失败',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : const Color(0xFF333A46),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '原体测成绩查询不受影响，可以稍后再试。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : const Color(0xFF737B8C),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '当前成绩里没有可用于对比的体测项目',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white60 : const Color(0xFF737B8C),
          ),
        ),
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  final PhysicalReportMetric metric;
  final bool isDark;

  const _HighlightRow({
    required this.metric,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFFFB020).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.star_rounded,
              size: 20,
              color: Color(0xFFFFA000),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              metric.metricInfo.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF20232A),
              ),
            ),
          ),
          Text(
            '超过 ${metric.comparison.percentile}%',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF6366F1),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final PhysicalReportMetric metric;
  final bool isDark;

  const _MetricRow({
    required this.metric,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final comparison = metric.comparison;
    final comparable = comparison.isComparable;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.metricInfo.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF20232A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '成绩：${metric.studentResult.rawResult}',
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF7D8492),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    comparable ? '超过 ${comparison.percentile}%' : '暂无可比样本',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: comparable
                          ? const Color(0xFF6366F1)
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.45)
                              : const Color(0xFF9AA1AF)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    comparable ? '样本 ${comparison.sampleSize}' : '样本 0',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA1AF),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: comparable ? comparison.percentile / 100 : 0,
              minHeight: 6,
              backgroundColor:
                  isDark ? Colors.white10 : const Color(0xFFE9ECF3),
              color: comparable
                  ? const Color(0xFF6366F1)
                  : (isDark ? Colors.white24 : const Color(0xFFC8CDD8)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  final bool isDark;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _SurfaceCard({
    required this.isDark,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: child,
    );
  }
}
