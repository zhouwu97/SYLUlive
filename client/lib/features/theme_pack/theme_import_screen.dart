import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/about_app_sheet.dart';
import '../../widgets/app_card.dart';
import '../../widgets/floating_bottom_nav.dart';
import '../../widgets/liquid_bottom_nav.dart';
import '../../widgets/opacity_safe_backdrop_filter.dart';
import 'theme_appearance.dart';
import 'theme_appearance_exporter.dart';
import 'theme_contrast.dart';
import 'theme_downloads.dart';
import 'theme_font_registry.dart';
import 'theme_manifest.dart';
import 'theme_navigation_images.dart';
import 'theme_pack_codec.dart';
import 'theme_pack_store.dart';
import 'theme_presentation.dart';
import 'theme_trial_banner.dart';
import 'themed_wallpaper_layer.dart';

class ThemeImportScreen extends StatefulWidget {
  const ThemeImportScreen({
    super.key,
    this.installed,
    this.pickFile,
    this.appVersion,
    this.incomingRequest,
    this.downloadFile,
  });

  final InstalledTheme? installed;
  final Future<String?> Function()? pickFile;
  final String? appVersion;
  final ThemeIncomingRequest? incomingRequest;
  final ThemeDownloadFile? downloadFile;

  static bool get isIncomingRouteActive =>
      ThemeIncomingCoordinator.instance.hasActiveOwner;

  @override
  State<ThemeImportScreen> createState() => _ThemeImportScreenState();
}

class _ThemeImportScreenState extends State<ThemeImportScreen> {
  PreparedThemePack? _pack;
  late InstalledTheme? _installed = widget.installed;
  final _selected = <ThemeGroup>{};
  bool _reading = false;
  bool _saving = false;
  String? _error;
  bool _requiresUpdate = false;
  bool _fromDownloads = false;
  Brightness _brightness = Brightness.light;
  int _generation = 0;
  int? _incomingGeneration;
  final Object _ownerToken = Object();

  ThemeManifest? get _manifest => _installed?.manifest ?? _pack?.manifest;

  @override
  void initState() {
    super.initState();
    _brightness = context.read<ThemeProvider>().effectiveBrightness;
    if (_manifest != null) {
      _selected.addAll(ThemeGroup.defaultApply);
    }
    if (widget.incomingRequest != null) {
      ThemeIncomingCoordinator.instance.claimOwner(_ownerToken);
      ThemeIncomingCoordinator.instance.addListener(_onIncomingChanged);
      final active =
          ThemeIncomingCoordinator.instance.current ?? widget.incomingRequest!;
      _startIncoming(active, initialBuild: true);
    } else if (widget.downloadFile case final file?) {
      _fromDownloads = true;
      _reading = true;
      unawaited(_loadFromPath(file.name, ++_generation, download: file));
    }
  }

  @override
  void dispose() {
    if (widget.incomingRequest != null) {
      ThemeIncomingCoordinator.instance.removeListener(_onIncomingChanged);
      ThemeIncomingCoordinator.instance.releaseOwner(
        _ownerToken,
        generation: _incomingGeneration,
      );
    }
    super.dispose();
  }

  void _onIncomingChanged() {
    if (!mounted || !ThemeIncomingCoordinator.instance.isOwner(_ownerToken)) {
      return;
    }
    final latest = ThemeIncomingCoordinator.instance.current;
    if (latest == null || latest.generation == _incomingGeneration) return;
    _startIncoming(latest);
  }

  Future<String> _resolveAppVersion() async {
    return widget.appVersion ??
        (await PackageInfo.fromPlatform())
            .version
            .split('+')
            .first
            .split('-')
            .first;
  }

  void _startIncoming(
    ThemeIncomingRequest request, {
    bool initialBuild = false,
  }) {
    _incomingGeneration = request.generation;
    final generation = ++_generation;
    void applyFields(VoidCallback fn) {
      if (initialBuild) {
        fn();
      } else {
        setState(fn);
      }
    }

    if (request.errorCode != null) {
      final err = switch (request.errorCode) {
        'theme_too_large' => const ThemePackError('theme_too_large'),
        'permission_denied' => null,
        _ => const ThemePackError('theme_zip_invalid', 'file'),
      };
      applyFields(() {
        _reading = false;
        _requiresUpdate = false;
        _pack = null;
        _installed = null;
        _selected.clear();
        _error = err == null
            ? '无法读取这个文件。请检查文件访问权限后重新选择。'
            : '${err.message}\n${err.code}${err.field.isEmpty ? '' : ' · ${err.field}'}';
      });
      ThemeIncomingCoordinator.instance.clearIfMatches(request.generation);
      return;
    }
    final file = request.filePath;
    if (file == null || file.isEmpty) {
      applyFields(() {
        _reading = false;
        _requiresUpdate = false;
        _pack = null;
        _installed = null;
        _selected.clear();
        _error = '无法读取这个文件。请检查文件访问权限后重新选择。';
      });
      ThemeIncomingCoordinator.instance.clearIfMatches(request.generation);
      return;
    }
    applyFields(() {
      _reading = true;
      _error = null;
      _requiresUpdate = false;
      _pack = null;
      _installed = null;
      _selected.clear();
    });
    unawaited(_loadFromPath(file, generation, incomingGen: request.generation));
  }

  Future<void> _pick() async {
    _fromDownloads = false;
    final previousIncomingGen = _incomingGeneration;
    _incomingGeneration = null;
    if (previousIncomingGen != null) {
      ThemeIncomingCoordinator.instance.clearIfMatches(previousIncomingGen);
    }
    final generation = ++_generation;
    setState(() {
      _reading = true;
      _error = null;
      _requiresUpdate = false;
      _pack = null;
      _installed = null;
      _selected.clear();
    });
    try {
      final file = widget.pickFile != null
          ? await widget.pickFile!()
          : (await FilePicker.platform
                  .pickFiles(type: FileType.any, withData: false))
              ?.files
              .single
              .path;
      if (!mounted || generation != _generation) return;
      if (file == null) {
        setState(() => _reading = false);
        return;
      }
      await _loadFromPath(file, generation);
    } on ThemePackError catch (error) {
      if (mounted && generation == _generation) {
        _requiresUpdate = error.code == 'theme_app_too_old' ||
            error.code == 'theme_format_unsupported';
        setState(() {
          _reading = false;
          _error =
              '${error.message}\n${error.code}${error.field.isEmpty ? '' : ' · ${error.field}'}';
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _reading = false;
          _error = '无法读取这个文件。请检查文件访问权限后重新选择。';
        });
      }
    }
  }

  Future<void> _loadFromPath(
    String file,
    int generation, {
    int? incomingGen,
    ThemeDownloadFile? download,
  }) async {
    bool isStillCurrent() =>
        mounted &&
        generation == _generation &&
        (incomingGen == null ||
            ThemeIncomingCoordinator.instance.generation == incomingGen);
    try {
      if (!file.toLowerCase().endsWith('.sltheme')) {
        throw const ThemePackError(
            'theme_zip_invalid', 'file', '请选择 .sltheme 文件');
      }
      final version = await _resolveAppVersion();
      if (!isStillCurrent()) return;
      final pack = download == null
          ? await ThemePackCodec.readFile(file, appVersion: version)
          : await ThemePackCodec.decode(await ThemeDownloads.read(download),
              appVersion: version);
      if (!isStillCurrent()) return;
      setState(() {
        _pack = pack;
        _selected
          ..clear()
          ..addAll(ThemeGroup.defaultApply);
      });
    } on ThemePackError catch (error) {
      if (isStillCurrent()) {
        _requiresUpdate = error.code == 'theme_app_too_old' ||
            error.code == 'theme_format_unsupported';
        setState(() => _error =
            '${error.message}\n${error.code}${error.field.isEmpty ? '' : ' · ${error.field}'}');
      }
    } catch (_) {
      if (isStillCurrent()) {
        setState(() => _error = '无法读取这个文件。请检查文件访问权限后重新选择。');
      }
    } finally {
      if (incomingGen != null) {
        ThemeIncomingCoordinator.instance.clearIfMatches(incomingGen);
      }
      if (isStillCurrent()) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _startTrial() async {
    if (_saving || _reading || _selected.isEmpty || _manifest == null) return;
    final launchGen = _generation;
    final provider = context.read<ThemeProvider>();
    final groups = Set<ThemeGroup>.of(_selected);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await provider.startTrial(
        installed: _installed,
        pack: _pack,
        groups: groups,
      );
      if (!mounted || launchGen != _generation) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(false);
      }
    } catch (error) {
      if (mounted && launchGen == _generation) {
        setState(() =>
            _error = error is ThemePackError ? error.message : '无法开启试用，请重试。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _apply() async {
    if (_saving || _reading || _selected.isEmpty || _manifest == null) return;
    final launchGen = _generation;
    final provider = context.read<ThemeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final groups = Set<ThemeGroup>.of(_selected);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      InstalledTheme target;
      if (_installed != null) {
        target = _installed!;
      } else {
        final existing = await provider.themePacks.findInstalledVersion(
          _pack!.manifest.id,
          _pack!.manifest.version,
        );
        if (Platform.isAndroid && !_fromDownloads && existing == null) {
          final pack = _pack!;
          final name = ThemeAppearanceExporter.sanitizeFileName(
              pack.manifest.name, fallback: pack.manifest.id);
          await ThemeDownloads.save('$name-v${pack.manifest.version}.sltheme',
              await ThemePackCodec.encode(pack.manifest, pack.contents));
        }
        target = existing ?? await provider.installTheme(_pack!);
        if (mounted && launchGen == _generation) {
          _installed = target;
        }
      }
      if (!mounted || launchGen != _generation) return;
      await provider.applyInstalledTheme(target, groups);
      if (mounted && launchGen == _generation) {
        final appliedLauncherOnAndroid = groups.contains(ThemeGroup.launcherIcon) &&
            (Platform.isAndroid ||
                Theme.of(context).platform == TargetPlatform.android);
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop(true);
        }
        messenger.showSnackBar(
          SnackBar(
            persist: false,
            duration: const Duration(seconds: 5),
            content: Text(
              appliedLauncherOnAndroid
                  ? '主题已应用（桌面图标返回桌面后生效）'
                  : '主题已应用',
            ),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () async {
                try {
                  await provider.restorePreviousAppearance();
                } catch (_) {
                  if (messenger.mounted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('外观未能恢复，请在主题设置中重试。')),
                    );
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted && launchGen == _generation) {
        setState(() =>
            _error = error is ThemePackError ? error.message : '外观未能保存，请重试。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final issues = manifest == null
        ? const <ThemeContrastIssue>[]
        : ThemeContrast.check(manifest);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.installed == null ? '导入主题' : '应用主题',
            style: TextStyle(
              fontFamily: Theme.of(context).textTheme.titleLarge?.fontFamily,
            ),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                if (widget.installed == null && manifest == null)
                  AppCardSurface(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: tokens.card,
                      border: Border.all(color: tokens.cardBorder),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.folder_open_outlined,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '选择 .sltheme 文件',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '预览后选择要更换的外观。',
                          style: TextStyle(color: tokens.textSecondary),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: _reading || _saving ? null : _pick,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('选择主题文件'),
                        ),
                      ],
                    ),
                  ),
                if (widget.installed == null && manifest != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: _reading || _saving ? null : _pick,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: const Text('重新选择文件'),
                    ),
                  ),
                if (_reading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在检查主题与资源…'),
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.onErrorContainer),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_requiresUpdate)
                  TextButton.icon(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => const AboutAppSheet(),
                    ),
                    icon: const Icon(Icons.system_update),
                    label: const Text('检查更新'),
                  ),
                if (manifest != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    manifest.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text('${manifest.author} · v${manifest.version} · 本机主题'),
                  if (manifest.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(manifest.description),
                    ),
                  const SizedBox(height: 16),
                  SegmentedButton<Brightness>(
                    segments: const [
                      ButtonSegment(
                        value: Brightness.light,
                        label: Text('浅色预览'),
                        icon: Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: Brightness.dark,
                        label: Text('深色预览'),
                        icon: Icon(Icons.dark_mode_outlined),
                      ),
                    ],
                    selected: {_brightness},
                    onSelectionChanged: (value) =>
                        setState(() => _brightness = value.single),
                  ),
                  const SizedBox(height: 12),
                  ThemePreview(
                    manifest: manifest,
                    pack: _pack,
                    installed: _installed,
                    brightness: _brightness,
                    groups: _selected,
                  ),
                  if (issues.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: const Icon(Icons.contrast),
                      title: Text('${issues.length} 项对比度提醒'),
                      subtitle: const Text('本机主题仍可应用，请确认文字清晰可读'),
                      children: [
                        for (final issue in issues)
                          ListTile(
                            dense: true,
                            title: Text(
                              '${issue.brightness == Brightness.light ? '浅色' : '深色'} · ${issue.foreground} / ${issue.background}',
                            ),
                            subtitle: Text(
                              '${issue.ratio.toStringAsFixed(2)}:1，要求 ${issue.minimum}:1',
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Text('应用内容', style: Theme.of(context).textTheme.titleMedium),
                  for (final group in ThemeGroup.applicable)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(group.label),
                      subtitle: manifest.groups.contains(group)
                          ? null
                          : Text(group == ThemeGroup.launcherIcon
                              ? '此主题未包含'
                              : '使用默认${group.label}，取消勾选可保留当前设置'),
                      value: _selected.contains(group),
                      onChanged: _saving ||
                              (group == ThemeGroup.launcherIcon &&
                                  !manifest.groups.contains(group))
                          ? null
                          : (value) => setState(() {
                                value!
                                    ? _selected.add(group)
                                    : _selected.remove(group);
                              }),
                    ),
                  if (manifest.groups
                      .difference(ThemeGroup.applicable)
                      .isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '${manifest.groups.difference(ThemeGroup.applicable).map((group) => group.label).join('、')}已随主题保存，后续版本开放应用。',
                      ),
                    ),
                  const Text('默认完整应用主题，未提供的外观项目恢复默认。取消勾选可保留当前设置。明暗模式和文字大小沿用你的设置。'),
                ],
              ],
            ),
          ),
        ),
        bottomNavigationBar: manifest == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _saving || _reading || _selected.isEmpty
                                ? null
                                : _startTrial,
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text('试用'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              _saving || _reading || _selected.isEmpty
                                  ? null
                                  : _apply,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check),
                          label: Text(
                            _saving
                                ? '正在保存…'
                                : _installed == null
                                    ? '保存并应用'
                                    : '应用所选内容',
                            style: TextStyle(
                              fontFamily: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.fontFamily,
                            ),
                          ),
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

class ThemePreview extends StatefulWidget {
  const ThemePreview({
    super.key,
    required this.manifest,
    required this.brightness,
    required this.groups,
    this.pack,
    this.installed,
  });

  final ThemeManifest manifest;
  final Brightness brightness;
  final Set<ThemeGroup> groups;
  final PreparedThemePack? pack;
  final InstalledTheme? installed;

  @override
  State<ThemePreview> createState() => _ThemePreviewState();
}

class _ThemePreviewState extends State<ThemePreview> {
  final _visualIndex = ValueNotifier<double>(0);
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _syncPreviewFont();
  }

  @override
  void didUpdateWidget(covariant ThemePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manifest.id != widget.manifest.id ||
        oldWidget.manifest.version != widget.manifest.version ||
        oldWidget.groups.contains(ThemeGroup.font) !=
            widget.groups.contains(ThemeGroup.font)) {
      _syncPreviewFont();
    }
  }

  void _syncPreviewFont() {
    if (!widget.groups.contains(ThemeGroup.font)) return;
    final appearance = const ThemeAppearance.empty().apply(
      widget.manifest,
      const {ThemeGroup.font},
      widget.installed?.directory ?? '',
    );
    final fontGroup = appearance.group(ThemeGroup.font);
    if (fontGroup == null ||
        ThemeFontRegistry.resolvedFamilyFor(fontGroup) != null) {
      return;
    }
    unawaited(
      ThemeFontRegistry.ensureLoaded(
        fontGroup,
        inMemoryContents: widget.pack?.contents,
      ).then((loaded) {
        if (loaded != null && mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _visualIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.manifest;
    final groups = widget.groups;
    final installed = widget.installed;
    final pack = widget.pack;
    final brightness = widget.brightness;
    final appearance = context
        .watch<ThemeProvider>()
        .persistedAppearance
        .apply(manifest, groups, installed?.directory ?? '');
    final theme = appearance.buildTheme(brightness);
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final walls = appearance.group(ThemeGroup.wallpapers)?[mode] as Map?;
    final wallpaper =
        (walls?['home'] ?? walls?['global']) as Map<String, dynamic>?;
    ImageProvider assetImage(String file) {
      final bytes =
          pack?.contents[file.startsWith('/') ? file.substring(1) : file];
      return bytes == null
          ? FileImage(File(file)) as ImageProvider
          : MemoryImage(bytes);
    }

    final material = appearance.group(ThemeGroup.material)?[mode] as Map?;
    final opacity = (material?['componentOpacity'] as num? ?? 1).toDouble();
    final frosted = material?['frostedGlass'] as Map?;
    final strength = frosted?['enabled'] == true
        ? (frosted!['strength'] as num).toDouble()
        : 0.0;
    final navigation = appearance.group(ThemeGroup.navigation);
    final images = themeNavigationImages(navigation, imageProvider: assetImage);
    final originalIcons = navigation?['iconTint'] == 'original';
    void select(int index) {
      setState(() {
        _index = index;
        _visualIndex.value = index.toDouble();
      });
    }

    final cover = manifest.data['preview']
        [brightness == Brightness.light ? 'light' : 'dark'] as String;
    final image = pack != null
        ? MemoryImage(pack.contents[cover]!) as ImageProvider
        : FileImage(File('${installed!.directory}/$cover'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('作者效果图'),
          children: [
            SizedBox(
              height: 300,
              child: Image(
                image: image,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Center(child: Text('效果图无法读取')),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('应用效果预览', style: Theme.of(context).textTheme.titleMedium),
        ),
        ThemePresentationOverride(
          appearance: appearance,
          brightnessOverride: brightness,
          assetResolver: assetImage,
          child: Theme(
            data: theme,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ThemedWallpaperLayer(
                      settings: wallpaper,
                      imageProvider: wallpaper == null
                          ? null
                          : assetImage(wallpaper['portrait'] as String),
                    ),
                  ),
                  Builder(
                    builder: (previewContext) {
                      final cardStyle =
                          ThemeCardStyleSpec.resolve(previewContext);
                      final previewRadius = BorderRadius.circular(
                        theme.extension<AppShape>()!.md,
                      );
                      final previewShadows = cardStyle?.resolveBoxShadows(
                        brightness == Brightness.dark,
                      );
                      final previewBorder = cardStyle?.resolveBoxBorder(
                        theme.extension<AppPalette>()!.cardBorder,
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 12),
                          const HomeThemedHeaderBanner(feedModeLabel: '推荐'),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Container(
                              decoration: (previewShadows != null &&
                                      previewShadows.isNotEmpty)
                                  ? BoxDecoration(
                                      borderRadius: previewRadius,
                                      boxShadow: previewShadows,
                                    )
                                  : null,
                              child: ClipRRect(
                                borderRadius: previewRadius,
                                child: OpacitySafeBackdropFilter(
                                  enabled: strength > 0,
                                  filter: ui.ImageFilter.blur(
                                    sigmaX: 10 * strength,
                                    sigmaY: 10 * strength,
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: theme
                                          .extension<AppPalette>()!
                                          .card
                                          .withValues(alpha: opacity),
                                      borderRadius: previewRadius,
                                      border: previewBorder == const Border()
                                          ? null
                                          : previewBorder,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            '校园生活',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          const Text('课程、动态和日常，都有自己的颜色。'),
                                          const SizedBox(height: 12),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              FilledButton(
                                                onPressed: () {},
                                                child: Text(
                                                  '主要操作',
                                                  style: TextStyle(
                                                    fontFamily: theme
                                                        .textTheme
                                                        .labelLarge
                                                        ?.fontFamily,
                                                  ),
                                                ),
                                              ),
                                              OutlinedButton(
                                                onPressed: () {},
                                                child: const Text('次要操作'),
                                              ),
                                            ],
                                          ),
                                          Row(
                                            children: [
                                              const Expanded(
                                                child: Text('设置开关'),
                                              ),
                                              Switch(
                                                value: true,
                                                onChanged: (_) {},
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (navigation?['style'] == 'liquid_glass')
                            SizedBox(
                              height: 100,
                              child: LiquidBottomNav(
                                currentIndex: _index,
                                visualIndexListenable: _visualIndex,
                                onTap: select,
                                themeImages: images,
                                originalIcons: originalIcons,
                                shaderEnabled: false,
                              ),
                            )
                          else
                            FloatingBottomNav(
                              currentIndex: _index,
                              onTap: select,
                              docked: navigation?['style'] == 'normal',
                              themeImages: images,
                              originalIcons: originalIcons,
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
