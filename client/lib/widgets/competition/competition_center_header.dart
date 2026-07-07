import 'package:flutter/material.dart';
import 'competition_ui_tokens.dart';

class CompetitionCenterHeader extends StatelessWidget {
  final int myPlanCount;
  final int pendingTimeCount;
  final int adminTotalCount;
  final int adminDraftCount;
  final int adminPublishedCount;
  final int adminArchivedCount;
  final VoidCallback onPrimaryTap;
  final VoidCallback onSecondaryTap;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback onClearSearch;
  final VoidCallback onCategoryFilterTap;
  final VoidCallback onStatusFilterTap;
  final VoidCallback onMyPlanTap;
  final String filterSummary;
  final bool isAdmin;

  const CompetitionCenterHeader({
    super.key,
    required this.myPlanCount,
    required this.pendingTimeCount,
    required this.adminTotalCount,
    required this.adminDraftCount,
    required this.adminPublishedCount,
    required this.adminArchivedCount,
    required this.onPrimaryTap,
    required this.onSecondaryTap,
    required this.searchController,
    required this.onSearchSubmitted,
    required this.onClearSearch,
    required this.onCategoryFilterTap,
    required this.onStatusFilterTap,
    required this.onMyPlanTap,
    required this.filterSummary,
    required this.isAdmin,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _buildSearchField(isDark),
        const SizedBox(height: 12),
        _buildFilterBar(isDark),
        const SizedBox(height: 14),
        _buildOverviewBar(isDark),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildSearchField(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CompetitionUiTokens.pagePadding),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: CompetitionUiTokens.cardBg(isDark),
          borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
          border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, color: CompetitionUiTokens.subColor(isDark), size: 21),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: onSearchSubmitted,
                decoration: InputDecoration(
                  hintText: '搜索比赛名称 / 主办方 / 标签',
                  hintStyle: TextStyle(color: CompetitionUiTokens.subColor(isDark), fontSize: 14),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
                style: TextStyle(fontSize: 14, color: CompetitionUiTokens.titleColor(isDark)),
              ),
            ),
            if (searchController.text.isNotEmpty)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onClearSearch,
                icon: Icon(Icons.close_rounded, size: 18, color: CompetitionUiTokens.subColor(isDark)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CompetitionUiTokens.pagePadding),
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _buildSoftAction(
              icon: Icons.tune_rounded,
              label: '分类',
              onTap: onCategoryFilterTap,
              isDark: isDark,
              highlight: filterSummary != '全部比赛',
            ),
            const SizedBox(width: 10),
            _buildSoftAction(
              icon: Icons.sort_rounded,
              label: '状态',
              onTap: onStatusFilterTap,
              isDark: isDark,
              highlight: false,
            ),
            const SizedBox(width: 10),
            if (filterSummary != '全部比赛')
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    filterSummary,
                    style: TextStyle(
                      color: CompetitionUiTokens.accent(isDark),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CompetitionUiTokens.pagePadding),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: isAdmin
              ? [
                  _overviewItem('官方库', adminTotalCount, isDark),
                  const SizedBox(width: 16),
                  _overviewItem('草稿', adminDraftCount, isDark),
                  const SizedBox(width: 16),
                  _overviewItem('已发布', adminPublishedCount, isDark),
                  const SizedBox(width: 16),
                  _overviewItem('已归档', adminArchivedCount, isDark),
                ]
              : [
                  _overviewItem('我的计划', myPlanCount, isDark, onTap: onMyPlanTap),
                  const SizedBox(width: 16),
                  _overviewItem('待确认', pendingTimeCount, isDark),
                ],
        ),
      ),
    );
  }

  Widget _overviewItem(String label, int count, bool isDark, {VoidCallback? onTap}) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: CompetitionUiTokens.subColor(isDark),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: CompetitionUiTokens.titleColor(isDark),
          ),
        ),
      ],
    );

    if (onTap == null) return child;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: child,
      ),
    );
  }

  Widget _buildSoftAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isDark,
    bool highlight = false,
  }) {
    final bgColor = highlight
        ? CompetitionUiTokens.accentSoft(isDark)
        : (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white);
    final fgColor = highlight
        ? CompetitionUiTokens.accent(isDark)
        : CompetitionUiTokens.titleColor(isDark);
    final border = highlight
        ? null
        : Border.all(color: CompetitionUiTokens.borderColor(isDark));

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
            border: border,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fgColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
