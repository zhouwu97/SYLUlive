import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'campus_calendar_screen.dart';
import 'campus_map_tab_page.dart';
import 'edu_screen.dart';
import 'teacher_rate_screen.dart';

class CampusScreen extends StatefulWidget {
  const CampusScreen({super.key});

  @override
  State<CampusScreen> createState() => _CampusScreenState();
}

class _CampusScreenState extends State<CampusScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _currentSemesterText() {
    final now = DateTime.now();
    if (now.month >= 9) {
      return '${now.year}—${now.year + 1}学年 · 第一学期';
    }
    return '${now.year - 1}—${now.year}学年 · 第二学期';
  }

  Future<void> _openPage(Widget page) async {
    HapticFeedback.selectionClick();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101219) : const Color(0xFFF8F7FC),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _CampusHeader(semester: _currentSemesterText()),
                  const SizedBox(height: 18),
                  const _SchoolNoticePlaceholder(),
                  const SizedBox(height: 24),
                  const _SectionTitle(
                    title: '校园服务',
                    subtitle: '常用校园功能',
                  ),
                  const SizedBox(height: 12),
                  _buildServiceRow(isDark),
                  const SizedBox(height: 26),
                  const _SectionTitle(
                    title: '校园资讯',
                    subtitle: '学校官网文章与部门动态',
                  ),
                  const SizedBox(height: 12),
                  const _CampusArticlePlaceholder(),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceRow(bool isDark) {
    final services = <_CampusService>[
      _CampusService(
        title: '教务中心',
        icon: Icons.school_rounded,
        color: const Color(0xFF5D64C4),
        onTap: () => _openPage(const EduScreen()),
      ),
      _CampusService(
        title: '校园榜单',
        icon: Icons.leaderboard_rounded,
        color: const Color(0xFFF29A3F),
        onTap: () => _openPage(const TeacherRateScreen()),
      ),
      _CampusService(
        title: '校园地图',
        icon: Icons.map_rounded,
        color: const Color(0xFF3E92CC),
        onTap: () => _openPage(const CampusMapTabPage()),
      ),
      _CampusService(
        title: '校历',
        icon: Icons.calendar_month_rounded,
        color: const Color(0xFF40A578),
        onTap: () => _openPage(const CampusCalendarScreen()),
      ),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < services.length; index++) ...[
          Expanded(
            child: _CampusServiceCard(
              service: services[index],
              isDark: isDark,
            ),
          ),
          if (index != services.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class _CampusHeader extends StatelessWidget {
  final String semester;

  const _CampusHeader({required this.semester});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '校园',
                style: TextStyle(
                  fontSize: 27,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF20212B),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                semester,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        Icon(
          Icons.account_balance_rounded,
          size: 28,
          color: primary.withValues(alpha: 0.72),
        ),
      ],
    );
  }
}

class _SchoolNoticePlaceholder extends StatelessWidget {
  const _SchoolNoticePlaceholder();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final endColor =
        Color.lerp(primary, const Color(0xFF8B79C6), 0.58) ?? primary;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primary, endColor],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: isDark ? 0.16 : 0.22),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -18,
            top: -18,
            child: Icon(
              Icons.account_balance_rounded,
              size: 128,
              color: Colors.white.withValues(alpha: 0.075),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.17),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.campaign_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          SizedBox(width: 5),
                          Text(
                            '学校公告',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '待接入',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.82),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '学校官方公告内容接入中',
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '后续将在这里展示教务处、学生工作处及学校相关部门发布的重要通知。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '沈阳理工大学 · 官方信息',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.66),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF242530),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
      ],
    );
  }
}

class _CampusService {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CampusService({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _CampusServiceCard extends StatelessWidget {
  final _CampusService service;
  final bool isDark;

  const _CampusServiceCard({
    required this.service,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? const Color(0xFF1B1E28) : Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: service.onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          height: 96,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: service.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  service.icon,
                  color: service.color,
                  size: 22,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                service.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF292A35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CampusArticlePlaceholder extends StatelessWidget {
  const _CampusArticlePlaceholder();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  Icons.newspaper_rounded,
                  color: primary,
                  size: 23,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '校园资讯内容接入中',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF292A35),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '后续将展示学校官网、教务处和学生工作等公开文章。',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Divider(
            height: 1,
            color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
          ),
          const SizedBox(height: 15),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(label: '学校要闻'),
              _InfoChip(label: '教务通知'),
              _InfoChip(label: '学生活动'),
              _InfoChip(label: '后勤服务'),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;

  const _InfoChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.055)
            : const Color(0xFFF6F4FA),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: isDark ? Colors.white54 : const Color(0xFF666776),
        ),
      ),
    );
  }
}
