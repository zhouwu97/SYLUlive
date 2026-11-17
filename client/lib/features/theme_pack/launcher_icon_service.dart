import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../platform/contracts/preferences_store.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/settings/settings_page_scaffold.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_switch.dart';
import '../../widgets/settings/settings_tile.dart';
import 'theme_manifest.dart';

class BuiltinLauncherIconSpec {
  const BuiltinLauncherIconSpec({
    required this.id,
    required this.name,
    required this.bundled,
    required this.previewBackground,
    required this.previewForeground,
  });

  final String id;
  final String name;
  final bool bundled;
  final Color previewBackground;
  final Color previewForeground;
}

class LauncherIconState {
  const LauncherIconState({
    required this.activeId,
    required this.desiredId,
    required this.themed,
    this.androidSdkInt = 0,
    this.pinShortcutSupported = false,
  });

  final String activeId;
  final String desiredId;
  final bool themed;
  final int androidSdkInt;
  final bool pinShortcutSupported;

  bool get supportsThemedMonochrome => androidSdkInt >= 33;
}

enum PinShortcutStatus {
  requested,
  permissionRequired,
  unsupported,
  rejected,
  failed,
}

class PinShortcutResult {
  const PinShortcutResult(this.status, {this.message});
  final PinShortcutStatus status;
  final String? message;
}

/// 桌面图标与自定义快捷方式平台通道（Android 后台 alias + ShortcutManagerCompat / iOS AlternateIcon）。
class LauncherIconService {
  LauncherIconService._();

  static const MethodChannel channel = MethodChannel('app_icon');
  static const desiredIdKey = 'launcher_icon_id_v1';
  static const desiredThemedKey = 'launcher_icon_themed_v1';

  // 契约 3.2 内置备选桌面图标清单；在维护者 1024×1024 源图合入前仅打包 default。
  static const List<BuiltinLauncherIconSpec> builtinIcons = [
    BuiltinLauncherIconSpec(
      id: 'default',
      name: '沈理青',
      bundled: true,
      previewBackground: Color(0xFF147C72),
      previewForeground: Colors.white,
    ),
    BuiltinLauncherIconSpec(
      id: 'night',
      name: '墨夜',
      bundled: false,
      previewBackground: Color(0xFF0E1113),
      previewForeground: Color(0xFF9EB5C0),
    ),
    BuiltinLauncherIconSpec(
      id: 'sea',
      name: '海盐蓝',
      bundled: false,
      previewBackground: Color(0xFF2F7FD8),
      previewForeground: Colors.white,
    ),
    BuiltinLauncherIconSpec(
      id: 'sakura',
      name: '樱粉',
      bundled: false,
      previewBackground: Color(0xFFC9617E),
      previewForeground: Colors.white,
    ),
    BuiltinLauncherIconSpec(
      id: 'paper',
      name: '纸感',
      bundled: false,
      previewBackground: Color(0xFFF6F0E2),
      previewForeground: Color(0xFF3E6B4F),
    ),
    BuiltinLauncherIconSpec(
      id: 'campus',
      name: '校园四季',
      bundled: false,
      previewBackground: Color(0xFF4E8A5A),
      previewForeground: Colors.white,
    ),
  ];

  static String normalizeContractId(String? raw) {
    for (final spec in builtinIcons) {
      if (spec.id == raw) return spec.id;
    }
    return 'default';
  }

  static Future<bool> readDesiredThemed(AppPreferencesStore prefs) async {
    return prefs.getBool(desiredThemedKey) ?? false;
  }

  static Future<String> readDesiredId(AppPreferencesStore prefs) async {
    return normalizeContractId(prefs.getString(desiredIdKey));
  }

  static Future<void> setDesired({
    required AppPreferencesStore prefs,
    required String id,
    required bool themed,
  }) async {
    final normalized = normalizeContractId(id);
    await prefs.setString(desiredIdKey, normalized);
    await prefs.setBool(desiredThemedKey, themed);
    try {
      await channel.invokeMethod<void>('setDesired', {
        'id': normalized,
        'themed': themed,
      });
    } on MissingPluginException {
      // 桌面端或测试未挂载平台实现时仅保留偏好。
    }
  }

  static Future<LauncherIconState> current(AppPreferencesStore prefs) async {
    final fallbackId = await readDesiredId(prefs);
    final fallbackThemed = await readDesiredThemed(prefs);
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>('current');
      if (raw == null) {
        return LauncherIconState(
          activeId: fallbackId,
          desiredId: fallbackId,
          themed: fallbackThemed,
        );
      }
      return LauncherIconState(
        activeId: (raw['activeId'] as String?) ?? fallbackId,
        desiredId: (raw['desiredId'] as String?) ?? fallbackId,
        themed: (raw['themed'] as bool?) ?? fallbackThemed,
        androidSdkInt: (raw['sdkInt'] as num?)?.toInt() ?? 0,
        pinShortcutSupported: (raw['pinShortcutSupported'] as bool?) ?? false,
      );
    } on MissingPluginException {
      return LauncherIconState(
        activeId: fallbackId,
        desiredId: fallbackId,
        themed: fallbackThemed,
      );
    }
  }

  static Future<PinShortcutResult> requestPinThemeShortcut({
    required String imagePath,
    required String themeId,
    required String label,
  }) async {
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>(
        'requestPinThemeShortcut',
        {
          'path': imagePath,
          'id': themeId,
          'label': label,
        },
      );
      final status = raw?['status'] as String?;
      final message = raw?['message'] as String?;
      return PinShortcutResult(
        switch (status) {
          'requested' => PinShortcutStatus.requested,
          'permission_required' => PinShortcutStatus.permissionRequired,
          'unsupported' => PinShortcutStatus.unsupported,
          'rejected' => PinShortcutStatus.rejected,
          _ => PinShortcutStatus.failed,
        },
        message: message,
      );
    } on MissingPluginException {
      return const PinShortcutResult(PinShortcutStatus.unsupported);
    } catch (error) {
      return PinShortcutResult(
        PinShortcutStatus.failed,
        message: error.toString(),
      );
    }
  }

  static Future<bool> openShortcutPermissionSettings() async {
    try {
      final opened =
          await channel.invokeMethod<bool>('openShortcutPermissionSettings');
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }
}

class LauncherIconSettingsScreen extends StatefulWidget {
  const LauncherIconSettingsScreen({super.key});

  @override
  State<LauncherIconSettingsScreen> createState() =>
      _LauncherIconSettingsScreenState();
}

class _LauncherIconSettingsScreenState extends State<LauncherIconSettingsScreen>
    with WidgetsBindingObserver {
  LauncherIconState? _state;
  bool _busy = false;
  bool _pendingPermissionRetry = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
      if (_pendingPermissionRetry) {
        _pendingPermissionRetry = false;
        _pinCustomShortcut();
      }
    }
  }

  Future<void> _reload() async {
    final prefs = await AppPreferencesStore.getInstance();
    final current = await LauncherIconService.current(prefs);
    if (mounted) {
      setState(() => _state = current);
    }
  }

  Future<void> _selectBuiltin(String id, bool themed) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final prefs = await AppPreferencesStore.getInstance();
      await LauncherIconService.setDesired(
        prefs: prefs,
        id: id,
        themed: themed,
      );
      await _reload();
      if (!mounted) return;
      if (Platform.isAndroid ||
          Theme.of(context).platform == TargetPlatform.android) {
        messenger.showSnackBar(
          const SnackBar(content: Text('返回桌面后生效，部分桌面需要几秒刷新')),
        );
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('桌面图标未能切换，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  (String path, String themeId, String label)? _resolveCustomShortcutSource(
    ThemeProvider provider,
  ) {
    final group = provider.appearance.group(ThemeGroup.launcherIcon);
    final customPath = group?['custom'] as String?;
    if (customPath == null || customPath.isEmpty) return null;
    final source = group?['source'] as Map?;
    final themeId = (source?['themeId'] as String?) ?? 'custom';
    final name = (source?['name'] as String?)?.trim();
    return (
      customPath,
      themeId,
      (name != null && name.isNotEmpty) ? '沈理校园' : '沈理校园',
    );
  }

  Future<void> _pinCustomShortcut() async {
    if (_busy) return;
    final provider = context.read<ThemeProvider>();
    final custom = _resolveCustomShortcutSource(provider);
    if (custom == null) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await LauncherIconService.requestPinThemeShortcut(
        imagePath: custom.$1,
        themeId: custom.$2,
        label: custom.$3,
      );
      if (!mounted) return;
      switch (result.status) {
        case PinShortcutStatus.requested:
          messenger.showSnackBar(
            const SnackBar(content: Text('已发起桌面快捷方式请求，请在系统弹窗确认')),
          );
        case PinShortcutStatus.permissionRequired:
          final goSettings = await showAppDialog<bool>(
            context: context,
            builder: (dialogContext) => AppAlertDialog(
              title: const Text('需要桌面快捷方式权限'),
              content: const Text(
                '当前系统（MIUI / HyperOS）关闭了“桌面快捷方式”权限。请前往应用权限设置开启后返回，应用将自动继续添加。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('前往权限设置'),
                ),
              ],
            ),
          );
          if (goSettings == true) {
            _pendingPermissionRetry = true;
            await LauncherIconService.openShortcutPermissionSettings();
          }
        case PinShortcutStatus.rejected:
          messenger.showSnackBar(
            const SnackBar(content: Text('桌面拒绝了快捷方式创建请求，请检查桌面设置')),
          );
        case PinShortcutStatus.unsupported:
          messenger.showSnackBar(
            const SnackBar(content: Text('当前桌面不支持添加自定义快捷方式')),
          );
        case PinShortcutStatus.failed:
          messenger.showSnackBar(
            SnackBar(content: Text(result.message ?? '添加快捷方式失败，请重试')),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final provider = context.watch<ThemeProvider>();
    final state = _state;
    final customSource = _resolveCustomShortcutSource(provider);
    final isAndroid = Platform.isAndroid ||
        Theme.of(context).platform == TargetPlatform.android;

    return SettingsPageScaffold(
      title: '桌面图标',
      children: [
        if (state == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SettingsSection(
            title: '内置桌面图标',
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAndroid
                          ? '期望图标：${_labelFor(state.desiredId)} · 当前已启用：${_labelFor(state.activeId)}（返回桌面后自动切换）'
                          : '当前图标：${_labelFor(state.activeId)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: LauncherIconService.builtinIcons.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisExtent: 128,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemBuilder: (context, index) {
                        final spec = LauncherIconService.builtinIcons[index];
                        final selected = state.desiredId == spec.id;
                        return _IconOptionCard(
                          spec: spec,
                          selected: selected,
                          enabled: !_busy && spec.bundled,
                          onTap: () => _selectBuiltin(spec.id, state.themed),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (isAndroid && state.supportsThemedMonochrome)
                SettingsTile(
                  icon: Icons.tonality_outlined,
                  title: '跟随系统主题色',
                  subtitle: 'Android 13+ 开启系统“主题图标”时以单色剪影显示',
                  showChevron: false,
                  trailing: SettingsSwitch(
                    value: state.themed,
                    onChanged: _busy
                        ? null
                        : (next) => _selectBuiltin(state.desiredId, next),
                  ),
                ),
            ],
          ),
          if (isAndroid &&
              state.pinShortcutSupported &&
              customSource != null)
            SettingsSection(
              title: '当前主题自定义图标',
              children: [
                SettingsTile(
                  icon: Icons.add_to_home_screen_outlined,
                  title: '用主题图标添加桌面快捷方式',
                  subtitle: '在桌面创建带主题专属图标的启动快捷方式，不影响原有入口',
                  enabled: !_busy,
                  onTap: _pinCustomShortcut,
                ),
              ],
            ),
        ],
      ],
    );
  }

  static String _labelFor(String id) {
    for (final item in LauncherIconService.builtinIcons) {
      if (item.id == id) return item.name;
    }
    return id;
  }
}

class _IconOptionCard extends StatelessWidget {
  const _IconOptionCard({
    required this.spec,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final BuiltinLauncherIconSpec spec;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Opacity(
      opacity: spec.bundled ? 1.0 : 0.55,
      child: AppCardSurface(
        decoration: BoxDecoration(
          color: selected
              ? tokens.primaryContainer.withValues(alpha: 0.45)
              : tokens.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? tokens.primary : tokens.cardBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 圆形遮罩预览
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: spec.previewBackground,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.school_rounded,
                        size: 20,
                        color: spec.previewForeground,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 圆角方形遮罩预览
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: spec.previewBackground,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.school_rounded,
                        size: 20,
                        color: spec.previewForeground,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  spec.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: tokens.textPrimary,
                  ),
                ),
                Text(
                  spec.bundled
                      ? (selected ? '当前期望' : '可用')
                      : '待源图合入',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? tokens.primary : tokens.textSecondary,
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
