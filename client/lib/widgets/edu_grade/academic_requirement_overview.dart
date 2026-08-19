import 'package:flutter/material.dart';
import '../../models/edu_credit_requirement.dart';
import '../../theme/app_colors.dart';
import 'academic_requirement_card.dart';

/// 学分要求总览组件。
///
/// 展示全部学分模块列表，含标题和加载/缓存/错误状态。
class AcademicRequirementOverview extends StatefulWidget {
  final EduCreditRequirementOverview? requirements;
  final bool isLoading;
  final bool isBackgroundRefresh;
  final String? errorMessage;
  final bool hasCache;
  final VoidCallback? onRetry;

  const AcademicRequirementOverview({
    super.key,
    required this.requirements,
    this.isLoading = false,
    this.isBackgroundRefresh = false,
    this.errorMessage,
    this.hasCache = false,
    this.onRetry,
  });

  @override
  State<AcademicRequirementOverview> createState() =>
      _AcademicRequirementOverviewState();
}

class _AcademicRequirementOverviewState
    extends State<AcademicRequirementOverview> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final subColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
            child: Row(
              children: [
                Text(
                  '学分要求',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.isBackgroundRefresh)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandPrimary,
                    ),
                  ),
              ],
            ),
          ),

          // 内容
          if (widget.isLoading && !widget.hasCache) ...[
            ...List.generate(3, (_) => _buildSkeletonCard(isDark)),
          ] else if (widget.requirements != null &&
              widget.requirements!.modules.isNotEmpty) ...[
            for (final module in widget.requirements!.modules)
              AcademicRequirementCard(
                key: ValueKey(module.id),
                module: module,
              ),
          ] else if (widget.errorMessage != null && !widget.hasCache) ...[
            _buildErrorCard(
              isDark,
              subColor,
              widget.errorMessage!,
            ),
          ] else if (widget.requirements != null &&
              widget.requirements!.modules.isEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '教务系统暂未返回当前专业的学分要求',
                style: TextStyle(fontSize: 13, color: subColor),
              ),
            ),
          ],

          // 缓存过期提示
          if (widget.hasCache &&
              widget.errorMessage != null &&
              widget.requirements != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '更新失败，当前展示上次同步数据',
                style: TextStyle(fontSize: 12, color: subColor),
              ),
            ),

          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildSkeletonCard(bool isDark) {
    final cardBg = isDark ? const Color(0xFF1A1D21) : Colors.white;
    final shimmer =
        isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE6E9EC);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 160,
              height: 16,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: 120,
              height: 28,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              height: 6,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 180,
              height: 12,
              decoration: BoxDecoration(
                color: shimmer,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(
    bool isDark,
    Color subColor,
    String errorMessage,
  ) {
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final cardBg = isDark ? const Color(0xFF1A1D21) : Colors.white;
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE2E6EB);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _errorTitle(errorMessage),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF1F2328),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              errorMessage,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: subColor),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: widget.onRetry,
              style: TextButton.styleFrom(
                foregroundColor: accent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              child: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }

  String _errorTitle(String message) {
    if (message.contains('会话') ||
        message.contains('登录') ||
        message.contains('授权')) {
      return '教务会话需要恢复';
    }
    if (message.contains('连接') ||
        message.contains('网络') ||
        message.contains('超时') ||
        message.contains('不可用')) {
      return '教务服务连接失败';
    }
    if (message.contains('协议') || message.contains('格式')) {
      return '教务查询接口已变化';
    }
    if (message.contains('解析') || message.contains('结构')) {
      return '学分要求解析失败';
    }
    return '暂时无法获取学分要求';
  }
}
