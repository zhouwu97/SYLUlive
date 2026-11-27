import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/app_card.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_tile.dart';
import 'installed_themes_screen.dart';
import 'launcher_icon_service.dart';
import 'theme_appearance_exporter.dart';
import 'theme_appearance.dart';
import 'theme_beta_notice.dart';
import 'theme_import_screen.dart';
import 'theme_layout_decoration_screen.dart';
import 'theme_manifest.dart';
import 'theme_store_screen.dart';
import 'theme_submission_screen.dart';
import 'theme_workshop_samples.dart';

class ThemeSection extends StatefulWidget {
  const ThemeSection({
    super.key,
    this.onEditTheme,
    this.saveExportFile,
    this.shareExportFile,
    this.onAppearanceChanged,
  });

  final VoidCallback? onEditTheme;
  final VoidCallback? onAppearanceChanged;
  final Future<String?> Function(String fileName, Uint8List bytes)?
      saveExportFile;
  final Future<void> Function(String fileName, Uint8List bytes, Rect? origin)?
      shareExportFile;

  @override
  State<ThemeSection> createState() => _ThemeSectionState();
}

class _ThemeSectionState extends State<ThemeSection> {
  bool _busy = false;
  String? _error;

  Future<void> _change(Future<void> Function(ThemeProvider) action,
      {bool appearanceChanged = true}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(context.read<ThemeProvider>());
      if (mounted && appearanceChanged) widget.onAppearanceChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _error = '外观未能恢复，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 内置默认主题的构建回到首次启动载入的主题，而不是清空成无主题外观。
  Future<void> _restoreDefaultAppearance(ThemeProvider provider) async {
    if (!ThemeBetaNotice.enabled) return provider.restoreManualAppearance();
    final pack = await ThemeBetaNotice.loadPack(DefaultAssetBundle.of(context));
    final installed = await provider.installTheme(pack, reuseExisting: true);
    await provider.restoreManualAppearance(defaultTheme: installed);
  }

  Future<String> _currentAppVersion() async {
    try {
      return (await PackageInfo.fromPlatform())
          .version
          .split('+')
          .first
          .split('-')
          .first;
    } catch (_) {
      return '1.0.0';
    }
  }

  Future<void> _showExportOptions(ThemeProvider provider) async {
    if (_busy) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final colors = Theme.of(sheetContext).colorScheme;
        return AppCardSurface(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.share_outlined),
                    title: const Text('系统分享'),
                    subtitle: const Text('通过聊天或系统分享面板发送 .sltheme'),
                    onTap: () => Navigator.of(sheetContext).pop('share'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.save_alt_outlined),
                    title: const Text('保存到文件'),
                    subtitle: const Text('将当前混搭外观保存为本机 .sltheme 文件'),
                    onTap: () => Navigator.of(sheetContext).pop('save'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final version = await _currentAppVersion();
      final bytes = await provider.exportCurrentAppearance(
        appVersion: version,
        capturePreview: (manifest, contents) {
          if (!mounted) throw StateError('主题设置已关闭');
          final appearance = const ThemeAppearance.empty().apply(
            manifest, ThemeGroup.values.toSet(), '',
          );
          return ThemeWorkshopExportStage.capture(context, appearance, (path) {
            final bytes = contents[path.startsWith('/') ? path.substring(1) : path];
            return bytes == null ? null : MemoryImage(bytes);
          });
        },
      );
      if (!mounted) return;
      final fileName =
          '${ThemeAppearanceExporter.sanitizeFileName(provider.suggestedExportName)}.sltheme';
      if (action == 'share') {
        if (widget.shareExportFile != null) {
          await widget.shareExportFile!(fileName, bytes, origin);
        } else {
          await Share.shareXFiles(
            [
              XFile.fromData(
                bytes,
                name: fileName,
                mimeType: 'application/vnd.sylulive.theme+zip',
              ),
            ],
            fileNameOverrides: [fileName],
            sharePositionOrigin: origin,
          );
        }
      } else {
        final savedPath = widget.saveExportFile != null
            ? await widget.saveExportFile!(fileName, bytes)
            : await FilePicker.platform.saveFile(
                dialogTitle: '保存当前外观主题包',
                fileName: fileName,
                bytes: bytes,
              );
        if (savedPath != null && savedPath.isNotEmpty) {
          final target = File(savedPath);
          if (!await target.exists() || await target.length() == 0) {
            await target.parent.create(recursive: true);
            await target.writeAsBytes(bytes, flush: true);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已导出 $fileName')),
            );
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '当前外观导出失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _actionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontFamily: Theme.of(context).textTheme.labelLarge?.fontFamily,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return SettingsSection(
      title: '主题',
      children: [
        SettingsTile(
          icon: Icons.auto_awesome_outlined,
          title: '当前外观',
          subtitle: theme.currentAppearanceSummary,
          showChevron: false,
          maxSubtitleLines: 2,
          enabled: !_busy,
        ),
        SettingsTile(
          key: const ValueKey('theme-original-default'),
          icon: Icons.palette_outlined,
          title: '默认主题（经典）',
          subtitle: '使用主题商城上线前的配色、纯色背景和默认布局',
          enabled: !_busy,
          onTap: () =>
              _change((provider) => provider.applyOriginalDefaultAppearance()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionButton(
                  context: context,
                  icon: Icons.storefront_outlined,
                  label: '主题商城',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ThemeStoreScreen(),
                            ),
                          ),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.assignment_ind_outlined,
                  label: '我的投稿',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const MyThemeSubmissionsScreen(),
                            ),
                          ),
                ),
                if (widget.onEditTheme != null)
                  _actionButton(
                    context: context,
                    icon: Icons.construction_outlined,
                    label: '编辑主题',
                    onPressed: _busy ? null : widget.onEditTheme,
                  ),
                _actionButton(
                  context: context,
                  icon: Icons.palette_outlined,
                  label: '本机主题',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const InstalledThemesScreen(),
                            ),
                          ),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.file_open_outlined,
                  label: '导入主题',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<bool>(
                              builder: (_) => const ThemeImportScreen(),
                            ),
                          ),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.apps_rounded,
                  label: '桌面图标',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const LauncherIconSettingsScreen(),
                            ),
                          ),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.dashboard_customize_outlined,
                  label: '布局与装饰',
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const ThemeLayoutDecorationScreen(),
                            ),
                          ),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.ios_share_outlined,
                  label: '导出当前外观',
                  onPressed: _busy ? null : () => _showExportOptions(theme),
                ),
                _actionButton(
                  context: context,
                  icon: Icons.undo_rounded,
                  label: '恢复上一个外观',
                  onPressed: !_busy && theme.hasPreviousAppearance
                      ? () =>
                          _change((provider) => provider.restorePreviousAppearance())
                      : null,
                ),
                _actionButton(
                  context: context,
                  icon: Icons.settings_backup_restore,
                  label: ThemeBetaNotice.enabled ? '恢复默认外观' : '恢复手动外观',
                  onPressed: !_busy &&
                          (theme.persistedAppearance.data.isNotEmpty ||
                              theme.isInTrial)
                      ? () => _change(_restoreDefaultAppearance)
                      : null,
                ),
              ],
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Semantics(liveRegion: true, child: Text(_error!)),
          ),
        if (theme.themeStorageWarning != null)
          ListTile(
            title: Text(theme.themeStorageWarning!),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _change((theme) => theme.retryThemeFileCleanup(),
                      appearanceChanged: false),
              child: const Text('重试'),
            ),
          ),
      ],
    );
  }
}
