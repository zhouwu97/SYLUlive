import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/liquid_bottom_nav.dart';
import '../../widgets/floating_bottom_nav.dart';
import '../../theme/app_radius.dart';
import '../../widgets/liquid_glass/liquid_glass_qa_screen.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_tile.dart';
import '../../widgets/settings/settings_switch.dart';

/// 全量替换后的底栏设置，仅调节新材质，不再提供旧样式入口。
class BottomNavigationSettingsScreen extends StatelessWidget {
  const BottomNavigationSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return SettingsPageScaffold(title: '底部导航栏', children: [
      const _LivePreview(),
      const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('首次下载使用时，建议先调低动画强度；不需要液态效果可选择「关」，使用普通悬浮底栏。')),
      SettingsSection(title: '玻璃材质', children: [
        SettingsTile(
          icon: Icons.water_drop_outlined,
          title: '清透材质',
          subtitle: '减少雾化与着色，让背景更清晰地透过底栏',
          trailing: SettingsSwitch(
            key: const ValueKey('bottom-nav-clear-material'),
            value: theme.bottomNavClearMaterial,
            onChanged: theme.setBottomNavClearMaterial,
          ),
        ),
      ]),
      if (theme.bottomNavPerformanceMode != BottomNavPerformanceMode.off)
        SettingsSection(title: '动画强度', children: [
          SettingsSliderTile(
            icon: Icons.animation_outlined,
            title: '材质跟随强度',
            subtitle: '随拖动速度与受力改变拉伸、弯曲和回弹',
            value: theme.bottomNavAnimationIntensity,
            min: 0,
            max: 1,
            valueLabel: '${(theme.bottomNavAnimationIntensity * 100).round()}%',
            onChanged: theme.setBottomNavAnimationIntensity,
          ),
        ]),
      SettingsSection(title: '效果预设', children: [
        RadioGroup<BottomNavPerformanceMode>(
          groupValue: theme.bottomNavPerformanceMode,
          onChanged: (mode) {
            if (mode != null) theme.setBottomNavPerformanceMode(mode);
          },
          child: Column(children: [
            for (final mode in BottomNavPerformanceMode.values)
              _BottomNavPerformanceOption(
                  mode: mode,
                  selected: theme.bottomNavPerformanceMode == mode,
                  onTap: () => theme.setBottomNavPerformanceMode(mode)),
          ]),
        ),
      ]),
      if (kDebugMode)
        SettingsSection(title: '高级视觉特效', children: [
          SettingsTile(
              icon: Icons.tune_rounded,
              title: 'Liquid Glass Reference QA',
              subtitle: '开发专用纹理与光学对照页',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const LiquidGlassReferenceParityScreen()))),
        ]),
    ]);
  }
}

class _LivePreview extends StatefulWidget {
  const _LivePreview();
  @override
  State<_LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<_LivePreview> {
  final position = ValueNotifier(2.0);
  int selected = 2;
  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return ClipRRect(
        key: const ValueKey('bottom-nav-preview-card'),
        borderRadius: BorderRadius.circular(AppRadius.sheet),
        child: SizedBox(
            height: 190,
            child: LiquidGlassScene(
              background: const DecoratedBox(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                        Color(0xffb1d5e2),
                        Color(0xffecd0d7),
                        Color(0xffdce9fa)
                      ])),
                  child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('液态玻璃底栏\n拖动预览，感受不同速度下的形变'))),
              overlay: Align(
                  alignment: Alignment.bottomCenter,
                  child: theme.bottomNavPerformanceMode ==
                          BottomNavPerformanceMode.off
                      ? FloatingBottomNav(
                          currentIndex: selected,
                          onTap: (index) => setState(() => selected = index))
                      : LiquidBottomNav(
                          currentIndex: selected,
                          visualIndexListenable: position,
                          onTap: (index) => setState(() => selected = index),
                          intensity: theme.bottomNavAnimationIntensity,
                          blur: theme.bottomNavBlur,
                          tint: theme.bottomNavTint,
                          shaderEnabled: theme.bottomNavShaderEnabled)),
            )));
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
      BottomNavPerformanceMode.off => '普通悬浮底栏，关闭液态形变与折射',
      BottomNavPerformanceMode.highPerformance => '保留完整液态玻璃，动画强度降至 35%',
      BottomNavPerformanceMode.highQuality => '完整折射与高光，动画强度拉满至 100%',
      BottomNavPerformanceMode.custom => '保留液态玻璃，自行调整动画强度',
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
