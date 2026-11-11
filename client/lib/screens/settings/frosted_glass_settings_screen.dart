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
    final saved = await theme.setComponentOpacityLevel(value);
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
              subtitle: !customBackground
                  ? '仅在自定义背景模式下生效'
                  : '调节卡片底色的通透程度',
              value: theme.componentOpacityLevel,
              min: 0,
              max: 1,
              divisions: 100,
              valueLabel: '${(theme.componentOpacityLevel * 100).round()}%',
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
                    ? '模糊卡片背后的背景，强度越高越柔和，0% 关闭模糊'
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
                onTap: () => _setOpacity(theme.componentOpacityLevel),
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
                      FrostedGlassPerformanceMode.off =>
                        '使用实色卡片，关闭背景模糊',
                      FrostedGlassPerformanceMode.highPerformance =>
                        '轻度雾化背景，不透明度 75%、模糊 35%',
                      FrostedGlassPerformanceMode.highQuality =>
                        '加深背景雾化，不透明度 0%、模糊 100%',
                      FrostedGlassPerformanceMode.custom =>
                        '自行调整卡片不透明度与背景模糊强度',
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
