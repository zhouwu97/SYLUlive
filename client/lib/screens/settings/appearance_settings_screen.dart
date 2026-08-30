import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/campus_segmented_control.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_tile.dart';
import '../../widgets/liquid_glass/liquid_glass_qa_screen.dart';
import '../../widgets/app_cached_image.dart';
import 'widgets/background_picker_sheet.dart';
import 'bottom_navigation_settings_screen.dart';

/// 外观与显示二级设置页
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

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

  Future<void> _handleLiquidGlassToggle(
    BuildContext context,
    ThemeProvider themeProvider,
    bool value,
  ) async {
    if (!value) {
      await themeProvider.setLiquidGlass(false);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('启用液态玻璃 2.0'),
        content: const Text(
          '液态玻璃效果使用高阶层叠加与高斯模糊渲染。在部分低配置设备上可能增加渲染开销，确定要开启吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开启'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await themeProvider.setLiquidGlass(true);
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
          alignment: isLandscapeBg ? Alignment.center : Alignment.topCenter,
          errorBuilder: (_, __, ___) => Container(color: pageBgColor),
        );
      } else {
        backgroundWidget = AppCachedImage.public(
          imageUrl: bgPath,
          fit: BoxFit.cover,
          alignment: isLandscapeBg ? Alignment.center : Alignment.topCenter,
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
    } else {
      backgroundWidget = Container(color: pageBgColor);
    }

    final cardOpacity = themeProvider.isCleanBackgroundMode
        ? 1.0
        : themeProvider.componentOpacity;

    final frameWidth = isLandscapeBg ? 230.0 : 122.0;
    final frameHeight = isLandscapeBg ? 130.0 : 216.0;

    return Container(
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
    final isLandscapeScreen =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final customBackgroundActive =
        themeProvider.isCustomBackgroundMode && themeProvider.hasAnyBackground;

    return SettingsPageScaffold(
      title: '外观与显示',
      children: [
        // 智能实时自适应微缩预览卡片
        _buildLivePreviewCard(context, themeProvider),

        // 主题模式段落
        SettingsSection(
          title: '界面主题模式',
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CampusSegmentedControl<AppBackgroundMode>(
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
            ),
          ],
        ),

        // 暗色模式与全屏渲染
        SettingsSection(
          title: '配色与暗色模式',
          children: [
            SettingsTile(
              icon: Icons.dark_mode_outlined,
              title: '深色模式',
              subtitle: '针对夜间环境优化，降低屏幕明亮度',
              trailing: SettingsSwitch(
                value: themeProvider.isDarkMode,
                onChanged: (val) => themeProvider.setDarkMode(val),
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
            SettingsSliderTile(
              icon: Icons.opacity_rounded,
              title: '组件卡片不透明度',
              subtitle: customBackgroundActive
                  ? '调整自定义背景上方卡片的透明程度'
                  : '仅在“自定义背景”模式下生效',
              value: themeProvider.componentOpacity,
              min: 0.1,
              max: 1.0,
              valueLabel: '${(themeProvider.componentOpacity * 100).toInt()}%',
              enabled: customBackgroundActive,
              onChanged: (val) => themeProvider.setComponentOpacity(val),
            ),
          ],
        ),

        // 视觉特效高级配置
        SettingsSection(
          title: '高级视觉特效',
          children: [
            SettingsTile(
              icon: Icons.auto_awesome_outlined,
              title: '液态玻璃 2.0 效果',
              subtitle: '启用高阶高斯模糊与多层折射质感',
              trailing: SettingsSwitch(
                value: themeProvider.liquidGlass,
                onChanged: (val) =>
                    _handleLiquidGlassToggle(context, themeProvider, val),
              ),
            ),
            SettingsTile(
              icon: Icons.navigation_outlined,
              title: '悬浮式底栏导航',
              subtitle: '底部导航栏独立胶囊化悬浮显示',
              trailing: SettingsSwitch(
                value: themeProvider.floatingNavBar,
                onChanged: (val) => themeProvider.setFloatingNavBar(val),
              ),
            ),
            if (kDebugMode)
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

        // 底栏采用独立二级页：样式、动效和设备性能策略在同一处完成配置。
        SettingsSection(
          title: '底部导航栏',
          children: [
            SettingsTile(
              icon: Icons.navigation_outlined,
              title: '底部导航栏',
              subtitle:
                  '${themeProvider.bottomNavStyle.label} · 动画 ${(themeProvider.bottomNavAnimationIntensity * 100).round()}%',
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
}
