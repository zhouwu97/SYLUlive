import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// 统一空态 / 加载态 / 错误态占位组件。
///
/// 契约（docs/design/DESIGN_QA.md §Empty/Error states）：
/// - icon 置于圆形浅底（loading 态以 24×24 spinner 替代）
/// - 主标题 + 可选副标题 + 可选操作按钮
/// - 淡入使用 AppMotion.fast（160ms）+ standard 曲线
class StatePlaceholder extends StatelessWidget {
  const StatePlaceholder({
    super.key,
    required this.title,
    this.icon,
    this.loading = false,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  }) : assert(icon != null || loading, 'icon 与 loading 必须至少提供其一');

  /// 主标题文案。
  final String title;

  /// 圆形底中的图标；[loading] 为 true 时忽略（显示 spinner）。
  final IconData? icon;

  /// 是否展示加载态（spinner 替代图标）。
  final bool loading;

  /// 可选的灰色副标题。
  final String? subtitle;

  /// 可选操作按钮文案。
  final String? actionLabel;

  /// 操作按钮回调；为 null 时不展示按钮。
  final VoidCallback? onAction;

  /// 紧凑模式：缩小的圆底与间距（用于聊天详情消息区）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? Colors.white60 : const Color(0xFF847A74);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: AnimatedOpacity(
          key: const ValueKey('state-placeholder'),
          opacity: 1,
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 消息区被键盘/表情面板压缩时退化为最小形态，避免纵向溢出。
              final tight =
                  constraints.maxHeight.isFinite && constraints.maxHeight < 160;
              final showSubtitle = subtitle != null && !tight;
              final showAction =
                  actionLabel != null && onAction != null && !tight;
              final circleSize = tight
                  ? 56.0
                  : compact
                      ? 64.0
                      : 84.0;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.07)
                          : const Color(0xFFF3EFEA),
                      shape: BoxShape.circle,
                    ),
                    child: loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                          )
                        : Icon(icon, size: compact ? 28 : 32, color: accent),
                  ),
                  SizedBox(
                      height: tight
                          ? 10
                          : compact
                              ? 14
                              : 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: tight ? 1 : null,
                    overflow: tight ? TextOverflow.ellipsis : null,
                    style: TextStyle(
                      fontSize: compact ? 15 : 17,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF332D2A),
                      height: 1.4,
                    ),
                  ),
                  if (showSubtitle) ...[
                    const SizedBox(height: 6),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF847A74),
                        height: 1.5,
                      ),
                    ),
                  ],
                  if (showAction) ...[
                    const SizedBox(height: 18),
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
