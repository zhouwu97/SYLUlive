import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_text_scaler.dart';
import '../../utils/responsive_util.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/campus_segmented_control.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_tile.dart';
import '../../widgets/app_cached_image.dart';
import 'widgets/background_picker_sheet.dart';
import 'bottom_navigation_settings_screen.dart';
import 'frosted_glass_settings_screen.dart';
import '../../widgets/app_card.dart';

/// 界面设置二级页
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  int _themeSaveGeneration = 0;

  Future<void> _handleThemeModeChange(
    BuildContext context,
    ThemeProvider themeProvider,
    ThemeMode mode,
  ) async {
    final generation = ++_themeSaveGeneration;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final saved = await themeProvider.setThemeMode(mode);
    if (!context.mounted || generation != _themeSaveGeneration || saved) return;

    messenger.showSnackBar(SnackBar(
      content: const Text('配色已切换，但未能保存，请重试'),
      action: SnackBarAction(
        label: '重试',
        onPressed: () => _handleThemeModeChange(
          context,
          themeProvider,
          themeProvider.themeMode,
        ),
      ),
    ));
  }

  Future<void> _handleBackgroundModeChange(
    BuildContext context,
    ThemeProvider themeProvider,
    AppBackgroundMode mode,
  ) async {
    if (mode == AppBackgroundMode.clean) {
      await themeProvider.setCleanBackgroundMode();
      return;
    }

    if (themeProvider.hasAnyBackground) {
      await themeProvider.trySetCustomBackgroundMode();
      return;
    }

    final isLandscapeScreen =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (context.mounted) {
      await BackgroundPickerSheet.show(
        context,
        isLandscape: isLandscapeScreen,
      );
    }
  }

  /// 智能自适应微缩预览模型 (引用全局 CampusTheme 标准规范 Token)
  Widget _buildLivePreviewCard(
      BuildContext context, ThemeProvider themeProvider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;

    // 统一引用全局主题规范 Token
    final pageBgColor = isDark ? CampusTheme.darkBg : CampusTheme.bg;
    final outerContainerBg = isDark
        ? CampusTheme.darkCard.withValues(alpha: 0.5)
        : kCleanWarmCardBorderLight.withValues(alpha: 0.4);

    final isLandscapeScreen =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final bgPath = themeProvider.shouldShowCustomBackground
        ? themeProvider.getCustomBackgroundImageFor(context)
        : null;

    final isLandscapeBg = isLandscapeScreen ||
        (bgPath != null &&
            themeProvider.landscapeBackgroundImage != null &&
            bgPath == themeProvider.landscapeBackgroundImage);

    Widget backgroundWidget;
    if (bgPath != null &&
        bgPath.isNotEmpty &&
        !themeProvider.isCleanBackgroundMode) {
      final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
      final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
      if (isAsset || isLocalFile) {
        final imageProvider = isAsset
            ? AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath))
                as ImageProvider
            : FileImage(File(bgPath)) as ImageProvider;
        backgroundWidget = Image(
          image: imageProvider,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => Container(color: pageBgColor),
        );
      } else {
        backgroundWidget = AppCachedImage.public(
          imageUrl: bgPath,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          memCacheWidth: 1024,
          memCacheHeight: 1024,
          errorWidget: (_, __, ___) => Container(color: pageBgColor),
        );
      }

      // 微缩预览按实际显示比例缩小模糊值，避免小预览糊成一整块。
      final customBackgroundActive =
          themeProvider.isCustomBackgroundMode && bgPath.isNotEmpty;

      if (customBackgroundActive && themeProvider.backgroundBlur > 0.01) {
        final previewBlur =
            (themeProvider.backgroundBlur * 0.3).clamp(0.0, 9.0);

        backgroundWidget = ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: previewBlur,
              sigmaY: previewBlur,
            ),
            child: Transform.scale(
              scale: 1.0 + previewBlur / 100.0,
              child: backgroundWidget,
            ),
          ),
        );
      }
      // 缩略预览与真实页面保持相同明暗遮罩，深色下不再显示过亮壁纸。
      backgroundWidget = Stack(fit: StackFit.expand, children: [
        ColoredBox(color: pageBgColor, child: backgroundWidget),
        ColoredBox(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ]);
    } else {
      backgroundWidget = Container(color: pageBgColor);
    }

    final cardOpacity = themeProvider.effectiveComponentOpacity;

    final frameWidth = isLandscapeBg ? 230.0 : 122.0;
    final frameHeight = isLandscapeBg ? 130.0 : 216.0;

    return AppCardSurface(
      height: 240,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: outerContainerBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : CampusTheme.softBorder,
        ),
      ),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: frameWidth,
          height: frameHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark ? Colors.white30 : Colors.white,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                backgroundWidget,
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? CampusTheme.darkCard : Colors.white)
                              .withValues(alpha: cardOpacity),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isDark
                                ? Colors.white10
                                : kCleanWarmCardBorderLight,
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          '实时预览',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: primaryColor,
                          ),
                        ),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? CampusTheme.darkCard : Colors.white)
                              .withValues(alpha: cardOpacity),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark
                                ? Colors.white10
                                : kCleanWarmCardBorderLight,
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.person_rounded,
                                size: 10,
                                color: primaryColor,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    height: 5,
                                    width: 45,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Colors.white70
                                          : CampusTheme.text,
                                      borderRadius: BorderRadius.circular(2.5),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Container(
                                    height: 3.5,
                                    width: 65,
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? Colors.white30
                                          : CampusTheme.subText,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final sideNavigation = ResponsiveUtil.useSideNavigation(context);
    final navigationTitle = sideNavigation ? '侧边导航栏' : '底部导航栏';
    final isLandscapeScreen =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final customBackgroundActive =
        themeProvider.isCustomBackgroundMode && themeProvider.hasAnyBackground;

    return SettingsPageScaffold(
      title: '界面设置',
      children: [
        // 智能实时自适应微缩预览卡片
        _buildLivePreviewCard(context, themeProvider),

        // 主题模式段落
        SettingsSection(
          title: '界面主题模式',
          showCard: false,
          children: [
            CampusSegmentedControl<AppBackgroundMode>(
              items: const [
                CampusSegmentItem(
                  value: AppBackgroundMode.clean,
                  label: '简洁模式',
                ),
                CampusSegmentItem(
                  value: AppBackgroundMode.custom,
                  label: '自定义背景',
                ),
              ],
              selectedValue: themeProvider.backgroundMode,
              onSelectionChanged: (mode) =>
                  _handleBackgroundModeChange(context, themeProvider, mode),
            ),
          ],
        ),

        SettingsSection(
          title: '配色模式',
          showCard: false,
          children: [
            CampusSegmentedControl<ThemeMode>(
              key: const ValueKey('appearance-theme-mode'),
              items: const [
                CampusSegmentItem(value: ThemeMode.system, label: '跟随系统'),
                CampusSegmentItem(value: ThemeMode.light, label: '浅色模式'),
                CampusSegmentItem(value: ThemeMode.dark, label: '深色模式'),
              ],
              selectedValue: themeProvider.themeMode,
              onSelectionChanged: (mode) =>
                  _handleThemeModeChange(context, themeProvider, mode),
            ),
          ],
        ),

        SettingsSection(
          title: '文字显示',
          children: [
            SettingsSliderTile(
              icon: Icons.format_size_rounded,
              title: '字体大小',
              subtitle: '调整应用内文字大小，系统字体设置继续叠加，最大显示为 150%',
              value: AppFontSizePreset.values
                  .indexOf(themeProvider.fontSizePreset)
                  .toDouble(),
              min: 0,
              max: 5,
              divisions: 5,
              valueLabel: _fontSizeLabel(themeProvider.fontSizePreset),
              semanticFormatterCallback: (value) => _fontSizeLabel(
                AppFontSizePreset.values[value.round().clamp(0, 5)],
              ),
              onChanged: (value) => themeProvider.setFontSizePreset(
                AppFontSizePreset.values[value.round().clamp(0, 5)],
              ),
            ),
          ],
        ),

        // 交互与视觉效果
        SettingsSection(
          title: '交互与视觉效果',
          children: [
            if (Platform.isAndroid ||
                Theme.of(context).platform == TargetPlatform.android)
              SettingsTile(
                icon: Icons.swipe_right_alt_rounded,
                title: '预测性返回手势',
                subtitle: 'Android 14+ 返回时预览上一页，默认关闭',
                trailing: SettingsSwitch(
                  value: themeProvider.predictiveBack,
                  onChanged: themeProvider.setPredictiveBack,
                ),
              ),
          ],
        ),

        // 自定义背景设置
        SettingsSection(
          title: '自定义背景偏好',
          children: [
            SettingsTile(
              icon: Icons.image_outlined,
              title: '选择背景图片',
              subtitle: themeProvider.hasAnyBackground
                  ? '已配置自定义壁纸，点击重选或调整'
                  : '尚未选择背景图，点击打开壁纸库',
              onTap: () {
                BackgroundPickerSheet.show(
                  context,
                  isLandscape: isLandscapeScreen,
                );
              },
            ),
            SettingsSliderTile(
              icon: Icons.blur_on_rounded,
              title: '背景高斯模糊',
              subtitle: customBackgroundActive
                  ? '仅模糊自定义背景图片，不影响文字、卡片和按钮'
                  : '仅在“自定义背景”模式下生效，请先选择背景图片',
              value: themeProvider.backgroundBlur,
              min: 0,
              max: 30,
              valueLabel: '${themeProvider.backgroundBlur.toInt()}px',
              enabled: customBackgroundActive,
              onChanged: (val) => themeProvider.setBackgroundBlur(val),
            ),
          ],
        ),

        SettingsSection(
          title: '卡片',
          children: [
            SettingsTile(
              icon: Icons.tune_rounded,
              title: '卡片外观',
              subtitle: '不透明度 ${(themeProvider.componentOpacityLevel * 100).round()}% · '
                  '${themeProvider.frostedGlass ? themeProvider.frostedGlassPresetLabel : '毛玻璃关闭'}',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const FrostedGlassSettingsScreen(),
              )),
            ),
          ],
        ),

        // 底栏采用独立二级页：样式、动效和设备性能策略在同一处完成配置。
        SettingsSection(
          title: navigationTitle,
          children: [
            SettingsTile(
              icon: Icons.navigation_outlined,
              title: navigationTitle,
              subtitle: _bottomNavSummary(themeProvider,
                  sideNavigation: sideNavigation),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BottomNavigationSettingsScreen(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _bottomNavSummary(ThemeProvider theme,
      {required bool sideNavigation}) {
    if (theme.bottomNavAnimationIntensity <= 0) {
      return sideNavigation ? '悬浮侧栏' : BottomNavStyle.floating.label;
    }
    final style = sideNavigation ? '液态玻璃侧栏' : BottomNavStyle.liquidGlass.label;
    final preset = theme.bottomNavPerformanceMode;
    return preset == BottomNavPerformanceMode.off
        ? style
        : '$style · ${preset.label}';
  }

  String _fontSizeLabel(AppFontSizePreset preset) {
    return '${preset.label} ${(preset.scaleFactor * 100).round()}%';
  }
}
