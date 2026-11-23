import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../screens/settings/appearance_settings_screen.dart';
import 'theme_pack_codec.dart';

class ThemeBetaNotice extends StatefulWidget {
  const ThemeBetaNotice({
    super.key,
    required this.child,
  });

  static const enabled = bool.fromEnvironment('BETA_THEME_DEFAULT');
  static const assetPath = 'assets/beta-theme/mingfeng.sltheme';

  final Widget child;

  /// 读取随包内置的默认主题；首次启动自动应用和「恢复默认外观」共用。
  static Future<PreparedThemePack> loadPack(AssetBundle bundle) async {
    final asset = await bundle.load(assetPath);
    final appVersion = (await PackageInfo.fromPlatform()).version;
    return ThemePackCodec.decode(
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      appVersion: appVersion,
    );
  }

  @override
  State<ThemeBetaNotice> createState() => _ThemeBetaNoticeState();
}

enum _BetaNoticeState { hidden, loading, applied, failed }

class _ThemeBetaNoticeState extends State<ThemeBetaNotice> {
  _BetaNoticeState _notice = _BetaNoticeState.hidden;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_applyDefault());
    });
  }

  Future<void> _applyDefault() async {
    final provider = context.read<ThemeProvider>();
    if (!provider.canApplyBetaDefault) {
      setState(() => _notice = _BetaNoticeState.hidden);
      return;
    }
    setState(() => _notice = _BetaNoticeState.loading);
    try {
      final pack =
          await ThemeBetaNotice.loadPack(DefaultAssetBundle.of(context));
      if (!mounted) return;
      if (!provider.canApplyBetaDefault) {
        setState(() => _notice = _BetaNoticeState.hidden);
        return;
      }
      final installed = await provider.installTheme(pack, reuseExisting: true);
      if (!mounted) return;
      final applied = await provider.applyInstalledTheme(
        installed,
        ThemeProvider.builtInDefaultGroups,
        asBetaDefault: true,
      );
      if (mounted) {
        setState(() => _notice =
            applied ? _BetaNoticeState.applied : _BetaNoticeState.hidden);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice = provider.canApplyBetaDefault
            ? _BetaNoticeState.failed
            : _BetaNoticeState.hidden);
      }
    }
  }

  void _openThemeSettings() {
    setState(() => _notice = _BetaNoticeState.hidden);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AppearanceSettingsScreen(showThemeFirst: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = switch (_notice) {
      _BetaNoticeState.loading => '正在加载「明风」主题…',
      _BetaNoticeState.applied => '主题商城正在 Beta 测试。本版本已默认启用「明风」，可前往主题设置恢复上一个外观。',
      _BetaNoticeState.failed => '「明风」主题加载失败，仍在使用当前外观。',
      _BetaNoticeState.hidden => '',
    };
    return Column(
      children: [
        if (_notice != _BetaNoticeState.hidden)
          SafeArea(
            bottom: false,
            child: MaterialBanner(
              content: Semantics(liveRegion: true, child: Text(message)),
              actions: [
                if (_notice == _BetaNoticeState.applied)
                  TextButton(
                    onPressed: _openThemeSettings,
                    child: const Text('前往主题设置'),
                  ),
                if (_notice == _BetaNoticeState.failed)
                  TextButton(
                    onPressed: _applyDefault,
                    child: const Text('重试'),
                  ),
                TextButton(
                  onPressed: _notice == _BetaNoticeState.loading
                      ? null
                      : () => setState(() => _notice = _BetaNoticeState.hidden),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        Expanded(
            child: MediaQuery.removePadding(
          context: context,
          removeTop: _notice != _BetaNoticeState.hidden,
          child: widget.child,
        )),
      ],
    );
  }
}
