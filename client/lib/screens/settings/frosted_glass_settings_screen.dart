import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/settings/settings_effect_option.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_tile.dart';

class FrostedGlassSettingsScreen extends StatefulWidget {
  const FrostedGlassSettingsScreen({super.key});

  @override
  State<FrostedGlassSettingsScreen> createState() =>
      _FrostedGlassSettingsScreenState();
}

class _FrostedGlassSettingsScreenState
    extends State<FrostedGlassSettingsScreen> {
  bool _glassSaveFailed = false;
  bool _opacitySaveFailed = false;
  int _glassGeneration = 0;
  int _opacityGeneration = 0;
  bool _glassRetryIncludesOpacity = false;
  // 开关材质会增减滤镜祖先，保留同一滑块状态以连续完成从关闭到开启的拖动。
  final _blurControlKey = GlobalKey();

  Future<void> _saveGlass(Future<bool> Function(ThemeProvider) save,
      {bool includesOpacity = false}) async {
    final theme = context.read<ThemeProvider>();
    if (!theme.shouldShowCustomBackground) return;
    final generation = ++_glassGeneration;
    _glassRetryIncludesOpacity |= includesOpacity;
    var saved = await save(theme);
    if (mounted &&
        generation == _glassGeneration &&
        saved &&
        _glassRetryIncludesOpacity &&
        !includesOpacity) {
      saved = await theme.saveFrostedGlassSettings(includeOpacity: true);
    }
    if (mounted && generation == _glassGeneration) {
      if (saved) _glassRetryIncludesOpacity = false;
      if (_glassSaveFailed != !saved) {
        setState(() => _glassSaveFailed = !saved);
      }
    }
  }

  Future<void> _setOpacity(double value) async {
    final theme = context.read<ThemeProvider>();
    if (!theme.shouldShowCustomBackground) return;
    final generation = ++_opacityGeneration;
    final saved = await theme.setComponentOpacity(value);
    if (mounted &&
        generation == _opacityGeneration &&
        _opacitySaveFailed != !saved) {
      setState(() => _opacitySaveFailed = !saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final mode = theme.frostedGlassPerformanceMode;
    final customBackground = theme.shouldShowCustomBackground;
    return SettingsPageScaffold(
      title: '卡片外观',
      children: [
        SettingsSection(
          title: '卡片调节',
          children: [
            SettingsSliderTile(
              key: const ValueKey('card-opacity'),
              icon: Icons.opacity_rounded,
              title: '卡片不透明度',
              subtitle:
                  !customBackground ? '仅在自定义背景模式下生效' : '直接观察本页卡片，预设后仍可自由调整',
              value: theme.componentOpacity.clamp(.1, 1),
              min: .1,
              max: 1,
              divisions: 90,
              valueLabel: '${(theme.componentOpacity * 100).round()}%',
              semanticFormatterCallback: (value) => '${(value * 100).round()}%',
              enabled: customBackground,
              onChanged: _setOpacity,
            ),
            KeyedSubtree(
              key: _blurControlKey,
              child: SettingsSliderTile(
                key: const ValueKey('card-blur-strength'),
                icon: Icons.blur_on_rounded,
                title: '毛玻璃强度',
                subtitle: customBackground
                    ? '直接观察本页卡片；0% 保留底色并停止背景模糊'
                    : '仅在自定义背景模式下生效',
                value: theme.frostedGlass ? theme.frostedGlassStrength : 0,
                divisions: 100,
                valueLabel:
                    '${(theme.frostedGlass ? theme.frostedGlassStrength * 100 : 0).round()}%',
                semanticFormatterCallback: (value) =>
                    '${(value * 100).round()}%',
                enabled: customBackground,
                onChanged: (value) =>
                    _saveGlass((theme) => theme.setFrostedGlassStrength(value)),
              ),
            ),
            if (_opacitySaveFailed)
              SettingsTile(
                icon: Icons.error_outline_rounded,
                title: '不透明度未保存',
                subtitle:
                    customBackground ? '当前效果仍有效，点击重试保存' : '切换到自定义背景后可重试保存',
                enabled: customBackground,
                onTap: () => _setOpacity(theme.componentOpacity),
              ),
            if (_glassSaveFailed)
              SettingsTile(
                icon: Icons.error_outline_rounded,
                title: '毛玻璃设置未保存',
                subtitle:
                    customBackground ? '当前效果仍有效，点击重试保存' : '切换到自定义背景后可重试保存',
                enabled: customBackground,
                onTap: () => _saveGlass(
                    (theme) => theme.saveFrostedGlassSettings(
                        includeOpacity: _glassRetryIncludesOpacity),
                    includesOpacity: _glassRetryIncludesOpacity),
              ),
          ],
        ),
        SettingsSection(
          title: '效果预设',
          children: [
            RadioGroup<FrostedGlassPerformanceMode>(
              groupValue: mode,
              onChanged: (value) {
                if (customBackground && value != null) {
                  _saveGlass(
                      (theme) => theme.setFrostedGlassPerformanceMode(value),
                      includesOpacity: true);
                }
              },
              child: Column(children: [
                for (final preset in FrostedGlassPerformanceMode.values)
                  SettingsEffectOption<FrostedGlassPerformanceMode>(
                    value: preset,
                    title: preset.label,
                    description: switch (preset) {
                      FrostedGlassPerformanceMode.off => '不透明度 100% · 关闭模糊',
                      FrostedGlassPerformanceMode.highPerformance =>
                        '不透明度 75% · 模糊强度 35%',
                      FrostedGlassPerformanceMode.highQuality =>
                        '不透明度 75% · 模糊强度 100%',
                      FrostedGlassPerformanceMode.custom =>
                        '不透明度 75% · 模糊强度 65%',
                    },
                    selected: mode == preset,
                    enabled: customBackground,
                    onTap: () => _saveGlass(
                        (theme) => theme.setFrostedGlassPerformanceMode(preset),
                        includesOpacity: true),
                  ),
              ]),
            ),
          ],
        ),
      ],
    );
  }
}
