import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';
import '../../features/theme_pack/theme_manifest.dart';
import '../../features/theme_pack/theme_navigation_images.dart';
import '../../utils/responsive_util.dart';
import '../../widgets/liquid_bottom_nav.dart';
import '../../widgets/floating_bottom_nav.dart';
import '../../widgets/app_card.dart';
import '../../widgets/liquid_glass/liquid_glass_qa_screen.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_tile.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_effect_option.dart';
import '../../widgets/settings/settings_effect_preview.dart';
import '../../theme/app_palette.dart';

/// 全量替换后的底栏设置，仅调节新材质，不再提供旧样式入口。
class BottomNavigationSettingsScreen extends StatefulWidget {
  const BottomNavigationSettingsScreen({super.key});

  @override
  State<BottomNavigationSettingsScreen> createState() =>
      _BottomNavigationSettingsScreenState();
}

class _BottomNavigationSettingsScreenState
    extends State<BottomNavigationSettingsScreen> {
  bool _saveFailed = false;
  int _saveGeneration = 0;

  Future<void> _saveEffect(Future<bool> Function(ThemeProvider) save) async {
    final generation = ++_saveGeneration;
    final saved = await save(context.read<ThemeProvider>());
    if (mounted && generation == _saveGeneration && _saveFailed != !saved) {
      setState(() => _saveFailed = !saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final sideNavigation = ResponsiveUtil.useSideNavigation(context);
    final navigationName = sideNavigation ? '侧栏' : '底栏';
    final style = theme.bottomNavStyle;
    final liquidActive = style == BottomNavStyle.liquidGlass &&
        theme.bottomNavPerformanceMode != BottomNavPerformanceMode.off;
    final activeMode = liquidActive
        ? theme.bottomNavPerformanceMode
        : BottomNavPerformanceMode.off;
    final activeIntensity = liquidActive ? theme.bottomNavAnimationIntensity : 0.0;
    final currentEffect = style == BottomNavStyle.normal
        ? '标准$navigationName'
        : liquidActive
            ? '液态玻璃$navigationName'
            : '悬浮$navigationName';
    return SettingsPageScaffold(
        title: sideNavigation ? '侧边导航栏' : '底部导航栏',
        children: [
          const _LivePreview(),
          AppCardSurface(
              margin: const EdgeInsets.symmetric(vertical: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppShape.of(context).lg),
              ),
              child: Text(
                  '当前效果：$currentEffect。\n'
                  '选择高性能、高画质或自定义可开启液态玻璃，沿用主题配色和图标。'
                  '开启后可${sideNavigation ? '上下' : '左右'}拖动预览。'
                  '选择「关」可使用普通悬浮$navigationName。')),
          SettingsSection(title: '玻璃材质', children: [
            SettingsTile(
              icon: Icons.water_drop_outlined,
              title: '清透材质',
              subtitle: '减少雾化与着色，让背景更清晰地透过$navigationName',
              trailing: SettingsSwitch(
                key: const ValueKey('bottom-nav-clear-material'),
                value: theme.bottomNavClearMaterial,
                onChanged: theme.setBottomNavClearMaterial,
              ),
            ),
          ]),
          SettingsSection(title: '动画强度', children: [
            SettingsSliderTile(
              key: const ValueKey('bottom-nav-intensity'),
              icon: Icons.animation_outlined,
              title: '材质跟随强度',
              subtitle: '调节形变与回弹幅度',
              value: activeIntensity,
              min: 0,
              max: 1,
              valueLabel:
                  '${(activeIntensity * 100).round()}%',
              onChanged: (value) => _saveEffect(
                  (theme) => theme.setBottomNavAnimationIntensity(value)),
            ),
            if (_saveFailed)
              SettingsTile(
                icon: Icons.error_outline_rounded,
                title: '液态效果设置未保存',
                subtitle: '当前效果仍有效，点击重试保存',
                onTap: () => _saveEffect((theme) =>
                    theme.setBottomNavPerformanceMode(
                        theme.bottomNavPerformanceMode)),
              ),
          ]),
          SettingsSection(title: '效果预设', children: [
            RadioGroup<BottomNavPerformanceMode>(
              groupValue: activeMode,
              onChanged: (mode) {
                if (mode != null) {
                  _saveEffect(
                      (theme) => theme.setBottomNavPerformanceMode(mode));
                }
              },
              child: Column(children: [
                for (final mode in BottomNavPerformanceMode.values)
                  _BottomNavPerformanceOption(
                      mode: mode,
                      selected: activeMode == mode,
                      onTap: () => _saveEffect(
                          (theme) => theme.setBottomNavPerformanceMode(mode))),
              ]),
            ),
          ]),
          if (kDebugMode)
            SettingsSection(title: '高级视觉特效', children: [
              SettingsTile(
                  icon: Icons.tune_rounded,
                  title: 'Liquid Glass Reference QA',
                  subtitle: '开发专用纹理与光学对照页',
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              const LiquidGlassReferenceParityScreen()))),
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
    final sideNavigation = ResponsiveUtil.useSideNavigation(context);
    final axis = sideNavigation ? Axis.vertical : Axis.horizontal;
    final navigation = theme.appearance.group(ThemeGroup.navigation);
    final images = themeNavigationImages(navigation);
    final originalIcons = navigation?['iconTint'] == 'original';
    return SettingsEffectPreview(
        clipKey: const ValueKey('bottom-nav-preview-card'),
        height: sideNavigation ? 480 : 220,
        child: LiquidGlassScene(
          background: SettingsEffectPreviewBackground(
              title: sideNavigation ? '侧栏效果预览' : '底栏效果预览',
              padding: sideNavigation
                  ? const EdgeInsets.fromLTRB(132, 20, 20, 20)
                  : const EdgeInsets.all(20)),
          overlay: Align(
              alignment: sideNavigation
                  ? Alignment.centerLeft
                  : Alignment.bottomCenter,
              child:
                  theme.bottomNavStyle != BottomNavStyle.liquidGlass ||
                          theme.bottomNavPerformanceMode == BottomNavPerformanceMode.off
                      ? FloatingBottomNav(
                          axis: axis,
                          docked: theme.bottomNavStyle == BottomNavStyle.normal,
                          themeImages: images,
                          originalIcons: originalIcons,
                          currentIndex: selected,
                          onTap: (index) => setState(() => selected = index))
                      : LiquidBottomNav(
                          axis: axis,
                          themeImages: images,
                          originalIcons: originalIcons,
                          currentIndex: selected,
                          visualIndexListenable: position,
                          onTap: (index) => setState(() => selected = index),
                          intensity: theme.bottomNavAnimationIntensity,
                          blur: theme.bottomNavBlur,
                          tint: theme.bottomNavTint,
                          shaderEnabled: theme.bottomNavShaderEnabled)),
        ));
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
    final navigationName =
        ResponsiveUtil.useSideNavigation(context) ? '侧栏' : '底栏';
    final description = switch (mode) {
      BottomNavPerformanceMode.off => '普通悬浮$navigationName，关闭液态形变与折射',
      BottomNavPerformanceMode.highPerformance => '保留完整液态玻璃，动画强度降至 35%',
      BottomNavPerformanceMode.highQuality => '完整折射与高光，动画强度拉满至 100%',
      BottomNavPerformanceMode.custom => '保留液态玻璃，自行调整动画强度',
    };
    return SettingsEffectOption<BottomNavPerformanceMode>(
      value: mode,
      title: mode.label,
      description: description,
      selected: selected,
      onTap: onTap,
    );
  }
}
