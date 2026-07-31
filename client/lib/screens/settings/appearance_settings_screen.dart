import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/campus_segmented_control.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_tile.dart';
import 'widgets/background_picker_sheet.dart';

/// 外观与显示设置二级页 (100% 像素级对齐效果图)
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  Future<void> _handleLiquidGlassToggle(
    BuildContext context,
    ThemeProvider themeProvider,
    bool enable,
  ) async {
    if (!enable) {
      await themeProvider.setLiquidGlass(false);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('液态玻璃效果'),
        content: const Text(
          '液态玻璃效果可能增加 GPU 负担，部分设备可能出现掉帧或发热。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: CampusTheme.orange,
            ),
            child: const Text('仍然开启'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await themeProvider.setLiquidGlass(true);
    }
  }

  /// 100% 还原效果图中的实时预览卡片
  Widget _buildLivePreviewCard(
      BuildContext context, ThemeProvider themeProvider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;
    final bgPath = themeProvider.shouldShowCustomBackground
        ? themeProvider.getCustomBackgroundImageFor(context)
        : null;

    Widget backgroundWidget;
    if (bgPath != null && bgPath.isNotEmpty) {
      final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
      final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
      final imageProvider = isAsset
          ? AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath))
              as ImageProvider
          : isLocalFile
              ? FileImage(File(bgPath)) as ImageProvider
              : NetworkImage(bgPath) as ImageProvider;

      backgroundWidget = Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        errorBuilder: (_, __, ___) => Container(
          color: isDark ? const Color(0xFF1E2322) : const Color(0xFFE5EEE9),
        ),
      );
    } else {
      backgroundWidget = Container(
        color: isDark ? const Color(0xFF1E2322) : const Color(0xFFE5EEE9),
      );
    }

    final cardOpacity = themeProvider.isCleanBackgroundMode
        ? 1.0
        : themeProvider.componentOpacity;

    return Container(
      height: 180,
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : CampusTheme.softBorder,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            backgroundWidget,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部绿字标签
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? CampusTheme.darkCard : Colors.white)
                          .withValues(alpha: cardOpacity),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '实时预览',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // 效果图专属中间卡片（大图标 + 双线 + 绿 Switch）
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? CampusTheme.darkCard : Colors.white)
                          .withValues(alpha: cardOpacity),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // 左侧图标块
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: primaryColor,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 24,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 14),
                        // 中间两条占位线条
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: double.infinity,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.7)
                                      : const Color(0xFF627370),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                width: 100,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white30
                                      : const Color(0xFFB4C4C0),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        // 右侧 Switch 示例
                        const IgnorePointer(
                          child: SettingsSwitch(value: true),
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
    );
  }

  Widget _buildBackgroundThumbnailPill(
      BuildContext context, ThemeProvider themeProvider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgPath = themeProvider.getCustomBackgroundImageFor(context);

    if (bgPath == null || bgPath.isEmpty) {
      return Container(
        width: 36,
        height: 22,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF383C42) : const Color(0xFFE2EEDD),
          borderRadius: BorderRadius.circular(11),
        ),
      );
    }

    final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
    final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
    final imageProvider = isAsset
        ? AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath))
            as ImageProvider
        : isLocalFile
            ? FileImage(File(bgPath)) as ImageProvider
            : NetworkImage(bgPath) as ImageProvider;

    return Container(
      width: 36,
      height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.2)
              : CampusTheme.softBorder,
        ),
        image: DecorationImage(
          image: imageProvider,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    final hasPortrait = themeProvider.hasBackground;
    final hasLandscape = themeProvider.hasLandscapeBackground;

    String bgStatusText;
    if (hasPortrait && hasLandscape) {
      bgStatusText = '竖屏已设置 · 横屏已设置';
    } else if (hasPortrait) {
      bgStatusText = '竖屏已设置 · 横屏未设置';
    } else if (hasLandscape) {
      bgStatusText = '竖屏未设置 · 横屏已设置';
    } else {
      bgStatusText = '未设置自定义背景图片';
    }

    return SettingsPageScaffold(
      title: '外观与显示',
      children: [
        _buildLivePreviewCard(context, themeProvider),

        // 背景模式 (使用专属平滑胶囊分段选择器，100% 对齐效果图)
        SettingsSection(
          title: '背景模式',
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
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
                onSelectionChanged: (mode) async {
                  if (mode == AppBackgroundMode.clean) {
                    await themeProvider.setCleanBackgroundMode();
                  } else {
                    final switched =
                        await themeProvider.trySetCustomBackgroundMode();
                    if (!switched && context.mounted) {
                      await BackgroundPickerSheet.show(context);
                    }
                  }
                },
              ),
            ),
          ],
        ),

        // 显示 (100% 对齐效果图)
        SettingsSection(
          title: '显示',
          children: [
            SettingsTile(
              icon: Icons.dark_mode_outlined,
              title: '夜间模式',
              subtitle: '使用深色页面与卡片配色',
              trailing: SettingsSwitch(
                value: themeProvider.isDarkMode,
                onChanged: (v) => themeProvider.setDarkMode(v),
              ),
            ),
            SettingsTile(
              icon: Icons.photo_library_outlined,
              title: '背景图片',
              subtitle: bgStatusText,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildBackgroundThumbnailPill(context, themeProvider),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.3)
                        : CampusTheme.subText.withValues(alpha: 0.5),
                  ),
                ],
              ),
              onTap: () => BackgroundPickerSheet.show(context),
            ),
          ],
        ),

        // 组件样式 (100% 对齐效果图)
        SettingsSection(
          title: '组件样式',
          children: [
            SettingsSliderTile(
              icon: Icons.opacity_rounded,
              title: '组件不透明度',
              subtitle: '仅在自定义背景模式下明显生效',
              value: themeProvider.componentOpacity,
              valueText: '${(themeProvider.componentOpacity * 100).round()}%',
              onChanged: (v) => themeProvider.setComponentOpacity(v),
            ),
            SettingsTile(
              icon: Icons.widgets_outlined,
              title: '悬浮底部导航栏',
              subtitle: '使用圆角悬浮式底部入口',
              trailing: SettingsSwitch(
                value: themeProvider.floatingNavBar,
                onChanged: (v) => themeProvider.setFloatingNavBar(v),
              ),
            ),
            SettingsTile(
              icon: Icons.undo_rounded,
              title: '预测性返回手势',
              subtitle: '侧滑时预览上一页',
              trailing: SettingsSwitch(
                value: themeProvider.predictiveBack,
                onChanged: (v) => themeProvider.setPredictiveBack(v),
              ),
            ),
            SettingsTile(
              icon: Icons.auto_awesome_outlined,
              title: '液态玻璃效果',
              subtitle: '增强背景层次，部分设备可能出现卡顿',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SettingsStatusBadge(
                    label: '性能影响',
                    type: SettingsStatusBadgeType.warning,
                  ),
                  const SizedBox(width: 8),
                  SettingsSwitch(
                    value: themeProvider.liquidGlass,
                    onChanged: (v) => _handleLiquidGlassToggle(
                      context,
                      themeProvider,
                      v,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
