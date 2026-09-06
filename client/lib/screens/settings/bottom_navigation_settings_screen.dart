import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/liquid_glass/liquid_glass_qa_screen.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_tile.dart';

/// 外观设置中的底部导航栏配置页。
///
/// 样式、动效和性能策略集中在这里，避免用户把“悬浮”和“液态玻璃”误解
/// 为两个互相独立、无法组合的开关。
class BottomNavigationSettingsScreen extends StatelessWidget {
  const BottomNavigationSettingsScreen({super.key});

  Future<void> _selectStyle(
    BuildContext context,
    ThemeProvider themeProvider,
    BottomNavStyle style,
  ) async {
    if (style != BottomNavStyle.liquidGlass ||
        themeProvider.bottomNavLiquidGlassConfirmed) {
      await themeProvider.setBottomNavStyle(style);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('启用液态玻璃底栏？'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('液态玻璃会增加 GPU 负载，部分设备可能降低续航或帧率。'),
            SizedBox(height: AppSpacing.md),
            _ConfirmationFeature(text: '悬浮底栏'),
            _ConfirmationFeature(text: '半透明玻璃'),
            _ConfirmationFeature(text: '动态折射'),
            _ConfirmationFeature(text: '手势跟随动画'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开启'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await themeProvider.setBottomNavLiquidGlassConfirmed(true);
      await themeProvider.setBottomNavStyle(BottomNavStyle.liquidGlass);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SettingsPageScaffold(
      title: '底部导航栏',
      children: [
        _BottomNavPreview(
          style: themeProvider.bottomNavStyle,
          isDark: isDark,
        ),
        const SizedBox(height: AppSpacing.lg),
        SettingsSection(
          title: '样式',
          children: [
            RadioGroup<BottomNavStyle>(
              groupValue: themeProvider.bottomNavStyle,
              onChanged: (style) {
                if (style != null) {
                  _selectStyle(context, themeProvider, style);
                }
              },
              child: Column(
                children: [
                  for (final style in BottomNavStyle.values)
                    _BottomNavStyleOption(
                      style: style,
                      selected: themeProvider.bottomNavStyle == style,
                      onTap: () => _selectStyle(context, themeProvider, style),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          title: '动画强度',
          children: [
            SettingsSliderTile(
              icon: Icons.animation_outlined,
              title: '材质跟随强度',
              subtitle: '优先移动 Lens，内容只保留轻微反馈',
              value: themeProvider.bottomNavAnimationIntensity,
              min: 0,
              max: 1,
              valueLabel:
                  '${(themeProvider.bottomNavAnimationIntensity * 100).round()}%',
              onChanged: themeProvider.setBottomNavAnimationIntensity,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('低', style: _secondaryTextStyle(isDark)),
                  Text('高', style: _secondaryTextStyle(isDark)),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          title: '性能模式',
          children: [
            RadioGroup<BottomNavPerformanceMode>(
              groupValue: themeProvider.bottomNavPerformanceMode,
              onChanged: (mode) {
                if (mode != null) {
                  themeProvider.setBottomNavPerformanceMode(mode);
                }
              },
              child: Column(
                children: [
                  for (final mode in BottomNavPerformanceMode.values)
                    _BottomNavPerformanceOption(
                      mode: mode,
                      selected: themeProvider.bottomNavPerformanceMode == mode,
                      onTap: () =>
                          themeProvider.setBottomNavPerformanceMode(mode),
                    ),
                ],
              ),
            ),
            _PerformanceHint(
              level: themeProvider.devicePerformanceLevel,
              isDark: isDark,
            ),
          ],
        ),
        // 液态玻璃光学 QA 仅在开发构建出现；底栏参数页是它的唯一入口。
        if (kDebugMode)
          SettingsSection(
            title: '高级视觉特效',
            children: [
              SettingsTile(
                icon: Icons.tune_rounded,
                title: 'Liquid Glass Reference QA',
                subtitle: '开发专用参考参数、纹理与光学对照页',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LiquidGlassReferenceParityScreen(),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  static TextStyle _secondaryTextStyle(bool isDark) {
    return AppTextStyles.bodyMedium.copyWith(
      color:
          isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
    );
  }
}

class _ConfirmationFeature extends StatelessWidget {
  const _ConfirmationFeature({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Icon(Icons.check_rounded, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Text(text),
        ],
      ),
    );
  }
}

class _BottomNavPreview extends StatelessWidget {
  const _BottomNavPreview({required this.style, required this.isDark});

  final BottomNavStyle style;
  final bool isDark;

  static const _labels = ['首页', '集市', '课表', '校园', '我'];
  static const _icons = [
    Icons.home_rounded,
    Icons.storefront_rounded,
    Icons.calendar_month_rounded,
    Icons.apartment_rounded,
    Icons.person_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final pageColor =
        isDark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight;
    final surfaceColor = isDark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;
    final isFloating = style != BottomNavStyle.normal;
    final isLiquid = style == BottomNavStyle.liquidGlass;

    return Semantics(
      label: '底部导航栏预览，当前为${style.label}',
      child: Container(
        height: 188,
        decoration: BoxDecoration(
          color: pageColor,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isDark
                ? AppColors.borderNormalDark
                : AppColors.borderNormalLight,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: 16,
              top: 16,
              child: Text(
                '预览区域',
                style: AppTextStyles.labelMedium.copyWith(
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    isFloating ? AppSpacing.md : 0,
                    0,
                    isFloating ? AppSpacing.md : 0,
                    isFloating ? AppSpacing.md : 0,
                  ),
                  child: Container(
                    height: 58,
                    decoration: BoxDecoration(
                      color: isLiquid
                          ? surfaceColor.withValues(alpha: isDark ? 0.66 : 0.74)
                          : surfaceColor,
                      borderRadius: BorderRadius.circular(
                        isFloating ? AppRadius.pill : 0,
                      ),
                      border: isFloating
                          ? Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.14)
                                  : AppColors.borderNormalLight,
                            )
                          : null,
                      boxShadow: isFloating
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: isDark ? 0.18 : 0.07,
                                ),
                                blurRadius: isLiquid ? 16 : 10,
                                offset: const Offset(0, 5),
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(
                        _labels.length,
                        (index) => _PreviewItem(
                          icon: _icons[index],
                          label: _labels[index],
                          selected: index == 0,
                          isDark: isDark,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.isDark,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? AppColors.brandPrimary
        : (isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: AppTextStyles.labelMedium.copyWith(color: color),
        ),
      ],
    );
  }
}

class _BottomNavStyleOption extends StatelessWidget {
  const _BottomNavStyleOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final BottomNavStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = switch (style) {
      BottomNavStyle.normal => '固定底栏，实色 surface，轻微阴影',
      BottomNavStyle.floating => '独立卡片，距离屏幕底部 12px',
      BottomNavStyle.liquidGlass => '悬浮底栏 + blur + lens + shader',
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '${style.label}，$subtitle',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Radio<BottomNavStyle>(
                  value: style,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        style.label,
                        style: AppTextStyles.bodyMedium.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        subtitle,
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavPerformanceOption extends StatelessWidget {
  const _BottomNavPerformanceOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final BottomNavPerformanceMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final description = switch (mode) {
      BottomNavPerformanceMode.auto => '按设备能力自动选择 blur 与 shader',
      BottomNavPerformanceMode.highPerformance => '保留 blur，关闭 shader，优先稳定帧率',
      BottomNavPerformanceMode.highQuality => '启用完整折射材质，可能增加 GPU 负载',
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '${mode.label}，$description',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Radio<BottomNavPerformanceMode>(
                  value: mode,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    mode.label,
                    style: AppTextStyles.bodyMedium.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppColors.textPrimaryDark
                          : AppColors.textPrimaryLight,
                    ),
                  ),
                ),
                Flexible(
                  flex: 2,
                  child: Text(
                    description,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondaryLight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PerformanceHint extends StatelessWidget {
  const _PerformanceHint({required this.level, required this.isDark});

  final DevicePerformanceLevel level;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final label = switch (level) {
      DevicePerformanceLevel.low => '低端设备：默认普通底栏',
      DevicePerformanceLevel.medium => '中端设备：默认悬浮 + blur，关闭 shader',
      DevicePerformanceLevel.high => '高端设备：可使用悬浮 + blur + lens + shader',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.speed_outlined,
            size: 18,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondaryLight,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '当前设备策略：$label',
              style: AppTextStyles.labelMedium.copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
