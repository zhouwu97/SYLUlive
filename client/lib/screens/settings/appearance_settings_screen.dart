import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/campus/campus_theme.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_slider_tile.dart';
import '../../widgets/settings/settings_status_badge.dart';
import '../../widgets/settings/settings_tile.dart';
import 'widgets/background_picker_sheet.dart';

/// 外观与显示设置二级页 (与设计效果图 100% 完全对齐)
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

  Widget _buildLivePreviewCard(
      BuildContext context, ThemeProvider themeProvider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        ),
      );
    } else {
      backgroundWidget = Container(
        color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
      );
    }

    final cardOpacity = themeProvider.isCleanBackgroundMode
        ? 1.0
        : themeProvider.componentOpacity;

    return Container(
      height: 180,
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : CampusTheme.softBorder,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.025),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            backgroundWidget,
            Container(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.15),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? CampusTheme.darkCard : Colors.white)
                              .withValues(alpha: cardOpacity),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '实时预览',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: CampusTheme.primary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (themeProvider.liquidGlass)
                        const SettingsStatusBadge(
                          label: '液态玻璃',
                          type: SettingsStatusBadgeType.info,
                        ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (isDark ? CampusTheme.darkCard : Colors.white)
                          .withValues(alpha: cardOpacity),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : CampusTheme.softBorder,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: CampusTheme.primaryLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                            color: CampusTheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '沈理校园 效果预览',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      isDark ? Colors.white : CampusTheme.text,
                                ),
                              ),
                              Text(
                                themeProvider.isCleanBackgroundMode
                                    ? '当前为暖白纯色简洁背景'
                                    : '当前不透明度 ${(cardOpacity * 100).round()}%',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? Colors.white60
                                      : CampusTheme.subText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: (isDark ? CampusTheme.darkCard : Colors.white)
                          .withValues(alpha: cardOpacity),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Icon(Icons.home_rounded,
                            size: 14, color: CampusTheme.primary),
                        Icon(Icons.calendar_month_rounded,
                            size: 14, color: CampusTheme.subText),
                        Icon(Icons.chat_bubble_outline_rounded,
                            size: 14, color: CampusTheme.subText),
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
        width: 32,
        height: 20,
        decoration: BoxDecoration(
          color: isDark ? Colors.white12 : Colors.grey[300],
          borderRadius: BorderRadius.circular(10),
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
      width: 32,
      height: 20,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
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

        // 背景模式 (与效果图 100% 对齐)
        SettingsSection(
          title: '背景模式',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: SegmentedButton<AppBackgroundMode>(
                segments: const [
                  ButtonSegment<AppBackgroundMode>(
                    value: AppBackgroundMode.clean,
                    label: Text('简洁模式'),
                  ),
                  ButtonSegment<AppBackgroundMode>(
                    value: AppBackgroundMode.custom,
                    label: Text('自定义背景'),
                  ),
                ],
                selected: {themeProvider.backgroundMode},
                onSelectionChanged: (selected) async {
                  final mode = selected.first;
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

        // 显示 (与效果图 100% 对齐)
        SettingsSection(
          title: '显示',
          children: [
            SettingsTile(
              icon: Icons.dark_mode_outlined,
              title: '夜间模式',
              subtitle: '使用深色页面与卡片配色',
              trailing: Switch(
                value: themeProvider.isDarkMode,
                onChanged: (v) => themeProvider.setDarkMode(v),
                activeThumbColor: CampusTheme.primary,
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

        // 组件样式 (与效果图 100% 对齐)
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
              trailing: Switch(
                value: themeProvider.floatingNavBar,
                onChanged: (v) => themeProvider.setFloatingNavBar(v),
                activeThumbColor: CampusTheme.primary,
              ),
            ),
            SettingsTile(
              icon: Icons.undo_rounded,
              title: '预测性返回手势',
              subtitle: '侧滑时预览上一页',
              trailing: Switch(
                value: themeProvider.predictiveBack,
                onChanged: (v) => themeProvider.setPredictiveBack(v),
                activeThumbColor: CampusTheme.primary,
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
                  Switch(
                    value: themeProvider.liquidGlass,
                    onChanged: (v) => _handleLiquidGlassToggle(
                      context,
                      themeProvider,
                      v,
                    ),
                    activeThumbColor: CampusTheme.primary,
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
