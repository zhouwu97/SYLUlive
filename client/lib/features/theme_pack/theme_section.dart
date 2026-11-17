import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_tile.dart';
import 'installed_themes_screen.dart';
import 'theme_import_screen.dart';

class ThemeSection extends StatefulWidget {
  const ThemeSection({super.key});
  @override
  State<ThemeSection> createState() => _ThemeSectionState();
}

class _ThemeSectionState extends State<ThemeSection> {
  bool _busy = false;
  String? _error;
  Future<void> _change(Future<void> Function(ThemeProvider) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(context.read<ThemeProvider>());
    } catch (_) {
      if (mounted) setState(() => _error = '外观未能恢复，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return SettingsSection(title: '主题', children: [
      SettingsTile(
          icon: Icons.file_open_outlined,
          title: '导入主题',
          subtitle: '选择 .sltheme 文件，按分组更换外观',
          enabled: !_busy,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<bool>(
              builder: (_) => const ThemeImportScreen()))),
      SettingsTile(
          icon: Icons.palette_outlined,
          title: '本机主题',
          subtitle: '预览、应用和分享已保存的主题',
          enabled: !_busy,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const InstalledThemesScreen()))),
      SettingsTile(
          icon: Icons.undo_rounded,
          title: '恢复上一个外观',
          subtitle: '保留完整外观，可再次切换回来',
          enabled: !_busy && theme.hasPreviousAppearance,
          onTap: () => _change((theme) => theme.restorePreviousAppearance())),
      SettingsTile(
          icon: Icons.settings_backup_restore,
          title: '恢复手动外观',
          subtitle: '使用应用主题前保存的壁纸和材质设置',
          enabled: !_busy && theme.appearance.data.isNotEmpty,
          onTap: () => _change((theme) => theme.restoreManualAppearance())),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
      if (theme.themeStorageWarning != null)
        ListTile(
            title: Text(theme.themeStorageWarning!),
            trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () => _change((theme) => theme.retryThemeFileCleanup()),
                child: const Text('重试'))),
    ]);
  }
}
