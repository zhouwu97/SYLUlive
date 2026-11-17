import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../widgets/liquid_bottom_nav.dart';
import '../../widgets/floating_bottom_nav.dart';
import '../../widgets/opacity_safe_backdrop_filter.dart';
import '../../theme/app_palette.dart';
import '../../widgets/about_app_sheet.dart';
import 'theme_contrast.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';
import 'theme_pack_store.dart';
import 'themed_wallpaper_layer.dart';
import 'theme_navigation_images.dart';

class ThemeImportScreen extends StatefulWidget {
  const ThemeImportScreen(
      {super.key, this.installed, this.pickFile, this.appVersion});
  final InstalledTheme? installed;
  final Future<String?> Function()? pickFile;
  final String? appVersion;

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
  Brightness _brightness = Brightness.light;
  int _generation = 0;
  ThemeManifest? get _manifest => _installed?.manifest ?? _pack?.manifest;

  @override
  void initState() {
    super.initState();
    _brightness = context.read<ThemeProvider>().effectiveBrightness;
    _selected
        .addAll(_manifest?.groups.intersection(ThemeGroup.applicable) ?? {});
  }

  Future<void> _pick() async {
    final generation = ++_generation;
    setState(() {
      _reading = true;
      _error = null;
      _requiresUpdate = false;
      _pack = null;
      _installed = null;
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
      if (file == null) return;
      if (!file.toLowerCase().endsWith('.sltheme')) {
        throw const ThemePackError(
            'theme_zip_invalid', 'file', '请选择 .sltheme 文件');
      }
      final version = widget.appVersion ??
          (await PackageInfo.fromPlatform())
              .version
              .split('+')
              .first
              .split('-')
              .first;
      final pack = await ThemePackCodec.readFile(file, appVersion: version);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pack = pack;
        _selected
          ..clear()
          ..addAll(pack.manifest.groups.intersection(ThemeGroup.applicable));
      });
    } on ThemePackError catch (error) {
      if (mounted && generation == _generation) {
        _requiresUpdate = error.code == 'theme_app_too_old' ||
            error.code == 'theme_format_unsupported';
        setState(() => _error =
            '${error.message}\n${error.code}${error.field.isEmpty ? '' : ' · ${error.field}'}');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '无法读取这个文件。请检查文件访问权限后重新选择。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _apply() async {
    if (_saving || _selected.isEmpty) return;
    final provider = context.read<ThemeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final groups = Set<ThemeGroup>.of(_selected);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _installed ??= await provider.installTheme(_pack!);
      if (!mounted) return;
      await provider.applyInstalledTheme(_installed!, groups);
      if (mounted) {
        Navigator.of(context).pop(true);
        messenger.showSnackBar(SnackBar(
            content: const Text('主题已应用'),
            action: SnackBarAction(
                label: '撤销',
                onPressed: () async {
                  try {
                    await provider.restorePreviousAppearance();
                  } catch (_) {
                    if (messenger.mounted) {
                      messenger.showSnackBar(
                          const SnackBar(content: Text('外观未能恢复，请在主题设置中重试。')));
                    }
                  }
                })));
      }
    } catch (error) {
      if (mounted) {
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
    final issues = manifest == null
        ? const <ThemeContrastIssue>[]
        : ThemeContrast.check(manifest);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
            title: Text(widget.installed == null ? '导入主题' : '应用主题',
                style: TextStyle(
                    fontFamily:
                        Theme.of(context).textTheme.titleLarge?.fontFamily))),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(18),
                  children: [
                    if (widget.installed == null) ...[
                      const Text('选择 .sltheme 文件，在预览后决定要更换哪些部分。'),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          onPressed: _reading || _saving ? null : _pick,
                          icon: const Icon(Icons.file_open_outlined),
                          label: Text(manifest == null ? '选择主题文件' : '重新选择文件')),
                    ],
                    if (_reading)
                      const Padding(
                          padding: EdgeInsets.all(32),
                          child: Column(children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('正在检查主题与资源…')
                          ])),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Semantics(
                              liveRegion: true, child: Text(_error!))),
                    if (_requiresUpdate)
                      TextButton.icon(
                          onPressed: () => showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              backgroundColor: Colors.transparent,
                              builder: (_) => const AboutAppSheet()),
                          icon: const Icon(Icons.system_update),
                          label: const Text('检查更新')),
                    if (manifest != null) ...[
                      const SizedBox(height: 16),
                      Text(manifest.name,
                          style: Theme.of(context).textTheme.headlineSmall),
                      Text('${manifest.author} · v${manifest.version} · 本机主题'),
                      if (manifest.description.isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(manifest.description)),
                      const SizedBox(height: 16),
                      SegmentedButton<Brightness>(
                          segments: const [
                            ButtonSegment(
                                value: Brightness.light,
                                label: Text('浅色预览'),
                                icon: Icon(Icons.light_mode_outlined)),
                            ButtonSegment(
                                value: Brightness.dark,
                                label: Text('深色预览'),
                                icon: Icon(Icons.dark_mode_outlined)),
                          ],
                          selected: {
                            _brightness
                          },
                          onSelectionChanged: (value) =>
                              setState(() => _brightness = value.single)),
                      const SizedBox(height: 12),
                      ThemePreview(
                          manifest: manifest,
                          pack: _pack,
                          installed: _installed,
                          brightness: _brightness,
                          groups: _selected),
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
                                      '${issue.brightness == Brightness.light ? '浅色' : '深色'} · ${issue.foreground} / ${issue.background}'),
                                  subtitle: Text(
                                      '${issue.ratio.toStringAsFixed(2)}:1，要求 ${issue.minimum}:1'))
                          ],
                        ),
                      const SizedBox(height: 16),
                      Text('应用内容',
                          style: Theme.of(context).textTheme.titleMedium),
                      for (final group in manifest.groups
                          .intersection(ThemeGroup.applicable))
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(group.label),
                          value: _selected.contains(group),
                          onChanged: _saving
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
                              '${manifest.groups.difference(ThemeGroup.applicable).map((group) => group.label).join('、')}已随主题保存，后续版本开放应用。'),
                        ),
                      const Text('明暗模式和文字大小沿用你的设置。未勾选的部分保持当前外观。'),
                    ],
                  ],
                ))),
        bottomNavigationBar: manifest == null
            ? null
            : SafeArea(
                child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: FilledButton.icon(
                    onPressed: _saving || _selected.isEmpty ? null : _apply,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
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
                                ?.fontFamily))),
              )),
      ),
    );
  }
}

class ThemePreview extends StatefulWidget {
  const ThemePreview(
      {super.key,
      required this.manifest,
      required this.brightness,
      required this.groups,
      this.pack,
      this.installed});
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
        .appearance
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                        const Center(child: Text('效果图无法读取')))),
          ]),
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child:
              Text('应用效果预览', style: Theme.of(context).textTheme.titleMedium)),
      Theme(
          data: theme,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(children: [
              Positioned.fill(
                  child: ThemedWallpaperLayer(
                      settings: wallpaper,
                      imageProvider: wallpaper == null
                          ? null
                          : assetImage(wallpaper['portrait'] as String))),
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 16),
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                          theme.extension<AppShape>()!.md),
                      child: OpacitySafeBackdropFilter(
                        enabled: strength > 0,
                        filter: ui.ImageFilter.blur(
                            sigmaX: 10 * strength, sigmaY: 10 * strength),
                        child: ColoredBox(
                          color: theme
                              .extension<AppPalette>()!
                              .card
                              .withValues(alpha: opacity),
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('校园生活',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 6),
                                    const Text('课程、动态和日常，都有自己的颜色。'),
                                    const SizedBox(height: 12),
                                    Wrap(spacing: 8, runSpacing: 8, children: [
                                      FilledButton(
                                          onPressed: () {},
                                          child: Text('主要操作',
                                              style: TextStyle(
                                                  fontFamily: theme
                                                      .textTheme
                                                      .labelLarge
                                                      ?.fontFamily))),
                                      OutlinedButton(
                                          onPressed: () {},
                                          child: const Text('次要操作')),
                                    ]),
                                    Row(children: [
                                      const Expanded(child: Text('设置开关')),
                                      Switch(value: true, onChanged: (_) {})
                                    ]),
                                  ])),
                        ),
                      ),
                    )),
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
                      ))
                else
                  FloatingBottomNav(
                      currentIndex: _index,
                      onTap: select,
                      docked: navigation?['style'] == 'normal',
                      themeImages: images,
                      originalIcons: originalIcons),
              ]),
            ]),
          )),
    ]);
  }
}
