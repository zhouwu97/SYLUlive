import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import 'canteen_pending_review_image.dart';

/// 待审核食堂卡片（纵向大图审核卡）：
/// 1. 顶部 16:9 大尺寸私有门面图（带鉴权加载与点击全屏查看）；
/// 2. 商家名称支持最多 2 行完整展示（移除“新食堂：”前缀及单行截断）；
/// 3. 次要信息区：提交人与提交时间降级展示；
/// 4. 底部独立操作栏：`[ 驳回 ]` 与 `[ 审核通过 ]` 触控热区 >= 44px。
class CanteenPendingCard extends StatelessWidget {
  final Map<String, dynamic> canteen;
  final bool isDark;
  final String? token;
  final int? accountId;
  final Future<void> Function()? onApprove;
  final Future<void> Function()? onReject;

  const CanteenPendingCard({
    super.key,
    required this.canteen,
    required this.isDark,
    this.token,
    this.accountId,
    this.onApprove,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final image = (canteen['image'] ?? '').toString();
    final creator = (canteen['creator_name'] ?? '').toString();
    final name = (canteen['name'] ?? '').toString();
    final canteenId = (canteen['id'] as num?)?.toInt();
    final createdAt =
        DateTime.tryParse((canteen['created_at'] ?? '').toString());

    String timeText = '';
    if (createdAt != null) {
      final local = createdAt.toLocal();
      timeText = '${local.year}/${local.month}/${local.day} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }

    final authProvider = context.watch<AuthProvider?>();
    final effectiveToken = token ?? authProvider?.token;
    final effectiveAccountId = accountId ?? authProvider?.user?.id;

    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final borderColor =
        isDark ? const Color(0x1FFFFFFF) : const Color(0xFFE8EEE9);
    final textPrimary =
        isDark ? Colors.white : const Color(0xFF1E242B);
    final textSecondary =
        isDark ? const Color(0xFFA0AAB3) : const Color(0xFF6B7280);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部 16:9 待审核门面图
          CanteenPendingReviewImage(
            imageUrl: image,
            canteenId: canteenId,
            token: effectiveToken,
            accountId: effectiveAccountId,
            height: 175,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(16),
            ),
          ),

          // 卡片信息区
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 商家名称（最多展示 2 行，移除单行截断与前缀）
                Text(
                  name.isEmpty ? '未命名商家' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),

                // 提交人信息
                Row(
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 15,
                      color: textSecondary,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '提交人：${creator.isEmpty ? '未知用户' : creator}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (timeText.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time_rounded,
                        size: 15,
                        color: textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '提交时间：$timeText',
                        style: TextStyle(
                          fontSize: 13,
                          color: textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),

                // 底部操作栏（明确的文字按钮，触控高度 >= 44px）
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onReject,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('驳回'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDark
                              ? const Color(0xFFEF9A9A)
                              : const Color(0xFFD32F2F),
                          side: BorderSide(
                            color: isDark
                                ? const Color(0xFFE57373).withValues(alpha: 0.5)
                                : const Color(0xFFEF9A9A),
                          ),
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onApprove,
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('审核通过'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.brandPrimary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
