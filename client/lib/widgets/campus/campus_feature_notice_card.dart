import 'package:flutter/material.dart';
import '../../models/campus_article.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
import 'campus_theme.dart';
import 'campus_notice_tag.dart';

class CampusFeatureNoticeCard extends StatefulWidget {
  final CampusArticleSummary article;
  final bool isDark;
  final VoidCallback onTap;

  const CampusFeatureNoticeCard({
    super.key,
    required this.article,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<CampusFeatureNoticeCard> createState() =>
      _CampusFeatureNoticeCardState();
}

class _CampusFeatureNoticeCardState extends State<CampusFeatureNoticeCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final isDark = widget.isDark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final motionPressed = !reduceMotion && _pressed;

    // 清洗标题中的学期前缀，让标题更清爽 (可选)
    // 假设文章标题为 "2025-2026-2第18周-实验..."
    // 简单替换掉前面的学期标识
    var displayTitle = article.title;
    final regex = RegExp(r'^\d{4}-\d{4}-\d[第-]?\d+周-?');
    if (regex.hasMatch(displayTitle)) {
      displayTitle = displayTitle.replaceFirst(regex, '');
    }

    final department =
        article.authorDepartment.isNotEmpty ? article.authorDepartment : '';

    final departmentInfo = [
      if (department.isNotEmpty) department,
      if (article.hasAttachment) '含附件',
    ].join(' · ');

    final surface = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (highlighted) {
          if (mounted) setState(() => _pressed = highlighted);
        },
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Ink(
          decoration: CampusTheme.cardDecoration(isDark, softGreen: true),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 56, 13),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CampusNoticeTag(
                            category: article.category.isNotEmpty
                                ? article.category
                                : '教务公告',
                          ),
                          const Spacer(),
                          Text(
                            article.publishDate.isNotEmpty
                                ? article.shortDate
                                : '',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color:
                                  isDark ? Colors.white54 : CampusTheme.subText,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.28,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white : CampusTheme.text,
                        ),
                      ),
                      if (departmentInfo.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          departmentInfo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            color:
                                isDark ? Colors.white54 : CampusTheme.subText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  right: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedContainer(
                      duration: reduceMotion ? Duration.zero : AppMotion.micro,
                      curve: AppMotion.standard,
                      width: motionPressed ? 36 : 32,
                      height: motionPressed ? 36 : 32,
                      decoration: BoxDecoration(
                        color: isDark
                            ? CampusTheme.primary.withValues(alpha: 0.18)
                            : CampusTheme.primaryLight,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: CampusTheme.primary.withValues(
                            alpha: isDark ? 0.3 : 0.12,
                          ),
                        ),
                      ),
                      child: AnimatedSlide(
                        duration:
                            reduceMotion ? Duration.zero : AppMotion.micro,
                        curve: AppMotion.standard,
                        offset: motionPressed
                            ? const Offset(0.08, 0)
                            : Offset.zero,
                        child: Icon(
                          Icons.arrow_outward_rounded,
                          size: 16,
                          color: isDark
                              ? CampusTheme.primaryLight
                              : CampusTheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (reduceMotion) return surface;
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1.0,
      duration: AppMotion.micro,
      curve: AppMotion.standard,
      child: surface,
    );
  }
}
