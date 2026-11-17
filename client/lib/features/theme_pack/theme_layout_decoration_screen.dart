import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/campus/campus_header.dart';
import 'theme_manifest.dart';
import 'theme_presentation.dart';

/// 壁纸与页头背景共用的几何及色彩矩阵调节面板（工坊与设置页共用）。
class ThemeImageAdjustmentsEditor extends StatelessWidget {
  const ThemeImageAdjustmentsEditor({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final Map<String, dynamic> settings;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  Widget build(BuildContext context) {
    final fit = settings['fit'] as String? ?? 'cover';
    final focalX = ((settings['focalX'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
    final focalY = ((settings['focalY'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
    final blur = ((settings['blur'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 20.0);
    final scrim = ((settings['scrim'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 0.6);
    final rawAdj = settings['adjustments'] as Map?;
    final brightness =
        ((rawAdj?['brightness'] as num?)?.toDouble() ?? 0.0).clamp(-100.0, 100.0);
    final contrast =
        ((rawAdj?['contrast'] as num?)?.toDouble() ?? 100.0).clamp(0.0, 200.0);
    final saturation =
        ((rawAdj?['saturation'] as num?)?.toDouble() ?? 100.0).clamp(0.0, 200.0);

    void patch(Map<String, dynamic> updates) {
      onChanged(<String, dynamic>{...settings, ...updates});
    }

    void patchAdj({double? b, double? c, double? s}) {
      final nextB = b ?? brightness;
      final nextC = c ?? contrast;
      final nextS = s ?? saturation;
      final next = Map<String, dynamic>.from(settings);
      if (nextB == 0 && nextC == 100 && nextS == 100) {
        next.remove('adjustments');
      } else {
        next['adjustments'] = {
          'brightness': nextB.roundToDouble(),
          'contrast': nextC.roundToDouble(),
          'saturation': nextS.roundToDouble(),
        };
      }
      onChanged(next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('缩放模式'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'cover', label: Text('铺满裁切')),
                ButtonSegment(value: 'contain', label: Text('完整显示')),
              ],
              selected: {fit == 'contain' ? 'contain' : 'cover'},
              onSelectionChanged: (v) => patch({'fit': v.single}),
            ),
          ],
        ),
        _LabeledSlider(
          label: '水平焦点 ${(focalX * 100).round()}%',
          value: focalX,
          min: 0,
          max: 1,
          onChanged: (v) => patch({'focalX': (v * 100).round() / 100}),
        ),
        _LabeledSlider(
          label: '垂直焦点 ${(focalY * 100).round()}%',
          value: focalY,
          min: 0,
          max: 1,
          onChanged: (v) => patch({'focalY': (v * 100).round() / 100}),
        ),
        _LabeledSlider(
          label: '模糊 ${blur.toStringAsFixed(1)}',
          value: blur,
          min: 0,
          max: 20,
          onChanged: (v) => patch({'blur': (v * 10).round() / 10}),
        ),
        _LabeledSlider(
          label: '遮罩浓度 ${(scrim * 100).round()}%',
          value: scrim,
          min: 0,
          max: 0.6,
          onChanged: (v) => patch({'scrim': (v * 100).round() / 100}),
        ),
        _LabeledSlider(
          label: '亮度 ${brightness.round()}',
          value: brightness,
          min: -100,
          max: 100,
          onChanged: (v) => patchAdj(b: v.roundToDouble()),
        ),
        _LabeledSlider(
          label: '对比度 ${contrast.round()}%',
          value: contrast,
          min: 0,
          max: 200,
          onChanged: (v) => patchAdj(c: v.roundToDouble()),
        ),
        _LabeledSlider(
          label: '饱和度 ${saturation.round()}%',
          value: saturation,
          min: 0,
          max: 200,
          onChanged: (v) => patchAdj(s: v.roundToDouble()),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              final reset = Map<String, dynamic>.from(settings)
                ..['fit'] = 'cover'
                ..['focalX'] = 0.5
                ..['focalY'] = 0.5
                ..['blur'] = 0.0
                ..['scrim'] = 0.0
                ..remove('adjustments');
              onChanged(reset);
            },
            child: const Text('重置图片参数'),
          ),
        ),
      ],
    );
  }
}

/// 卡片样式编辑器（borderWidth 与 shadow，工坊与设置页共用）。
class ThemeCardStyleEditor extends StatelessWidget {
  const ThemeCardStyleEditor({
    super.key,
    required this.cardStyle,
    required this.onChanged,
  });

  final Map<String, dynamic>? cardStyle;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  @override
  Widget build(BuildContext context) {
    final borderWidth = (cardStyle?['borderWidth'] as num?)?.toDouble();
    final shadow = cardStyle?['shadow'] as String?;

    void update({Object? bw = _unchanged, Object? sh = _unchanged}) {
      final next = Map<String, dynamic>.from(cardStyle ?? const {});
      if (!identical(bw, _unchanged)) {
        if (bw == null) {
          next.remove('borderWidth');
        } else {
          next['borderWidth'] = ((bw as double) * 10).round() / 10;
        }
      }
      if (!identical(sh, _unchanged)) {
        if (sh == null) {
          next.remove('shadow');
        } else {
          next['shadow'] = sh as String;
        }
      }
      onChanged(next.isEmpty ? null : next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                borderWidth == null
                    ? '描边宽度：默认'
                    : '描边宽度：${borderWidth.toStringAsFixed(1)} dp',
              ),
            ),
            if (borderWidth != null)
              TextButton(
                onPressed: () => update(bw: null),
                child: const Text('恢复默认描边'),
              ),
          ],
        ),
        Slider(
          value: (borderWidth ?? 1.0).clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          divisions: 20,
          label: (borderWidth ?? 1.0).toStringAsFixed(1),
          onChanged: (v) => update(bw: v),
        ),
        const SizedBox(height: 6),
        const Text('卡片阴影'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('默认'),
              selected: shadow == null,
              onSelected: (_) => update(sh: null),
            ),
            for (final item in const [
              ('none', '无阴影'),
              ('soft', '柔和'),
              ('medium', '明显'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: shadow == item.$1,
                onSelected: (_) => update(sh: item.$1),
              ),
          ],
        ),
      ],
    );
  }
}

/// 单个页头槽位的模板与图片区尺寸编辑器（工坊与设置页共用）。
class ThemeHeaderLayoutEditor extends StatelessWidget {
  const ThemeHeaderLayoutEditor({
    super.key,
    required this.slotLabel,
    required this.rawLayout,
    required this.onChanged,
  });

  final String slotLabel;
  final Map<String, dynamic>? rawLayout;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  @override
  Widget build(BuildContext context) {
    final spec = ThemeHeaderLayoutSpec.fromMap(rawLayout);
    void emit(ThemeHeaderLayoutSpec next) => onChanged(next.toJson());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$slotLabel 页头模板',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (rawLayout != null)
              TextButton(
                onPressed: () => onChanged(null),
                child: Text('重置$slotLabel布局'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in const [
              ('standard', '标准'),
              ('compact', '紧凑'),
              ('immersive', '沉浸'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: rawLayout != null && spec.preset == item.$1,
                onSelected: (_) => emit(
                  ThemeHeaderLayoutSpec(
                    preset: item.$1,
                    alignment: spec.alignment,
                    imageHeight: spec.imageHeight,
                    imageWidth: spec.imageWidth,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('信息区对齐'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in const [
              ('start', '靠左'),
              ('center', '居中'),
              ('end', '靠右'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: spec.alignment == item.$1,
                onSelected: (_) => emit(
                  ThemeHeaderLayoutSpec(
                    preset: spec.preset,
                    alignment: item.$1,
                    imageHeight: spec.imageHeight,
                    imageWidth: spec.imageWidth,
                  ),
                ),
              ),
          ],
        ),
        _LabeledSlider(
          label: '装饰区高度 ${spec.imageHeight.round()} dp',
          value: spec.imageHeight,
          min: 96,
          max: 280,
          onChanged: (v) => emit(
            ThemeHeaderLayoutSpec(
              preset: spec.preset,
              alignment: spec.alignment,
              imageHeight: v.roundToDouble(),
              imageWidth: spec.imageWidth,
            ),
          ),
        ),
        _LabeledSlider(
          label: '装饰区宽度 ${(spec.imageWidth * 100).round()}%',
          value: spec.imageWidth,
          min: 0.45,
          max: 1.0,
          onChanged: (v) => emit(
            ThemeHeaderLayoutSpec(
              preset: spec.preset,
              alignment: spec.alignment,
              imageHeight: spec.imageHeight,
              imageWidth: (v * 100).round() / 100,
            ),
          ),
        ),
      ],
    );
  }
}

/// 单个页头槽位的装饰背景与贴纸编辑器（支持拖拽贴纸和滑杆精确调节）。
class ThemeHeaderDecorationEditor extends StatefulWidget {
  const ThemeHeaderDecorationEditor({
    super.key,
    required this.slot,
    required this.slotLabel,
    required this.layoutSpec,
    required this.decoration,
    required this.assetResolver,
    required this.onPickHeaderBackground,
    required this.onPickSticker,
    required this.onChanged,
  });

  final String slot;
  final String slotLabel;
  final ThemeHeaderLayoutSpec layoutSpec;
  final Map<String, dynamic>? decoration;
  final ThemeAssetProviderResolver assetResolver;
  final Future<String?> Function() onPickHeaderBackground;
  final Future<String?> Function() onPickSticker;
  final ValueChanged<Map<String, dynamic>?> onChanged;

  @override
  State<ThemeHeaderDecorationEditor> createState() =>
      _ThemeHeaderDecorationEditorState();
}

class _ThemeHeaderDecorationEditorState
    extends State<ThemeHeaderDecorationEditor> {
  int _selectedSticker = 0;

  Map<String, dynamic>? get _bg {
    final raw = widget.decoration?['background'] as Map?;
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }

  List<Map<String, dynamic>> get _stickers => [
        for (final item in (widget.decoration?['stickers'] as List?) ?? const [])
          if (item is Map) Map<String, dynamic>.from(item),
      ];

  void _emit(Map<String, dynamic>? bg, List<Map<String, dynamic>> stickers) {
    if (bg == null && stickers.isEmpty) {
      widget.onChanged(null);
      return;
    }
    widget.onChanged({
      if (bg != null) 'background': bg,
      'stickers': stickers,
    });
  }

  Future<void> _selectBackground() async {
    final picked = await widget.onPickHeaderBackground();
    if (picked == null || !mounted) return;
    final prev = _bg;
    _emit(
      {
        'image': picked,
        'fit': prev?['fit'] ?? 'cover',
        'focalX': prev?['focalX'] ?? 0.5,
        'focalY': prev?['focalY'] ?? 0.5,
        'blur': prev?['blur'] ?? 0.0,
        'scrim': prev?['scrim'] ?? 0.0,
        if (prev?['adjustments'] != null) 'adjustments': prev!['adjustments'],
      },
      _stickers,
    );
  }

  Future<void> _addSticker() async {
    final stickers = _stickers;
    if (stickers.length >= 5) return;
    final picked = await widget.onPickSticker();
    if (picked == null || !mounted) return;
    final next = [
      ...stickers,
      {
        'image': picked,
        'x': 0.5,
        'y': 0.5,
        'width': 0.2,
        'rotation': 0.0,
      },
    ];
    setState(() => _selectedSticker = next.length - 1);
    _emit(_bg, next);
  }

  void _updateSticker(int index, Map<String, dynamic> patch) {
    final next = _stickers;
    if (index < 0 || index >= next.length) return;
    next[index] = {...next[index], ...patch};
    _emit(_bg, next);
  }

  void _removeSticker(int index) {
    final next = _stickers;
    if (index < 0 || index >= next.length) return;
    next.removeAt(index);
    if (_selectedSticker >= next.length) {
      _selectedSticker = next.isEmpty ? 0 : next.length - 1;
    }
    _emit(_bg, next);
  }

  @override
  Widget build(BuildContext context) {
    final bg = _bg;
    final stickers = _stickers;
    final activeIndex =
        stickers.isEmpty ? null : _selectedSticker.clamp(0, stickers.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${widget.slotLabel} 页头装饰',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (bg != null || stickers.isNotEmpty)
              TextButton(
                onPressed: () => widget.onChanged(null),
                child: Text('清空${widget.slotLabel}装饰'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _selectBackground,
              icon: const Icon(Icons.panorama_outlined, size: 18),
              label: Text(bg == null ? '选择背景图' : '更换背景图'),
            ),
            if (bg != null)
              OutlinedButton.icon(
                onPressed: () => _emit(null, stickers),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('移除背景图'),
              ),
            OutlinedButton.icon(
              onPressed: stickers.length >= 5 ? null : _addSticker,
              icon: const Icon(Icons.emoji_emotions_outlined, size: 18),
              label: Text('添加贴纸 (${stickers.length}/5)'),
            ),
          ],
        ),
        if (bg != null || stickers.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '拖拽画布（仅编辑模式可交互，正式页面不拦截点击）',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          ThemeHeaderDecorationArea(
            slot: widget.slot,
            layout: widget.layoutSpec,
            background: bg,
            stickers: stickers,
            assetResolver: widget.assetResolver,
            interactive: true,
            selectedStickerIndex: activeIndex,
            onStickerSelected: (i) => setState(() => _selectedSticker = i),
            onStickerDragChanged: (i, x, y) => _updateSticker(i, {
              'x': (x * 1000).round() / 1000,
              'y': (y * 1000).round() / 1000,
            }),
          ),
        ],
        if (bg != null) ...[
          const SizedBox(height: 12),
          Text('背景图效果', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          ThemeImageAdjustmentsEditor(
            settings: bg,
            onChanged: (updated) => _emit(updated, stickers),
          ),
        ],
        if (stickers.isNotEmpty && activeIndex != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < stickers.length; i++)
                ChoiceChip(
                  label: Text('贴纸 ${i + 1}'),
                  selected: i == activeIndex,
                  onSelected: (_) => setState(() => _selectedSticker = i),
                ),
              TextButton.icon(
                onPressed: () => _removeSticker(activeIndex),
                icon: const Icon(Icons.close, size: 16),
                label: Text('删除贴纸 ${activeIndex + 1}'),
              ),
            ],
          ),
          _LabeledSlider(
            label:
                '水平位置 X ${(((stickers[activeIndex]['x'] as num?)?.toDouble() ?? 0.5) * 100).round()}%',
            value: ((stickers[activeIndex]['x'] as num?)?.toDouble() ?? 0.5)
                .clamp(0.0, 1.0),
            min: 0,
            max: 1,
            onChanged: (v) =>
                _updateSticker(activeIndex, {'x': (v * 100).round() / 100}),
          ),
          _LabeledSlider(
            label:
                '垂直位置 Y ${(((stickers[activeIndex]['y'] as num?)?.toDouble() ?? 0.5) * 100).round()}%',
            value: ((stickers[activeIndex]['y'] as num?)?.toDouble() ?? 0.5)
                .clamp(0.0, 1.0),
            min: 0,
            max: 1,
            onChanged: (v) =>
                _updateSticker(activeIndex, {'y': (v * 100).round() / 100}),
          ),
          _LabeledSlider(
            label:
                '宽度比例 ${(((stickers[activeIndex]['width'] as num?)?.toDouble() ?? 0.2) * 100).round()}%',
            value: ((stickers[activeIndex]['width'] as num?)?.toDouble() ?? 0.2)
                .clamp(0.08, 0.40),
            min: 0.08,
            max: 0.40,
            onChanged: (v) =>
                _updateSticker(activeIndex, {'width': (v * 100).round() / 100}),
          ),
          _LabeledSlider(
            label:
                '旋转角度 ${((stickers[activeIndex]['rotation'] as num?)?.toDouble() ?? 0.0).round()}°',
            value:
                ((stickers[activeIndex]['rotation'] as num?)?.toDouble() ?? 0.0)
                    .clamp(-180.0, 180.0),
            min: -180,
            max: 180,
            onChanged: (v) =>
                _updateSticker(activeIndex, {'rotation': v.roundToDouble()}),
          ),
        ],
      ],
    );
  }
}

/// 外观设置页的本机“布局、卡片样式与页头装饰”编辑二级页。
class ThemeLayoutDecorationScreen extends StatefulWidget {
  const ThemeLayoutDecorationScreen({
    super.key,
    this.pickImagePath,
  });

  final Future<String?> Function(ThemeAssetKind kind)? pickImagePath;

  @override
  State<ThemeLayoutDecorationScreen> createState() =>
      _ThemeLayoutDecorationScreenState();
}

class _ThemeLayoutDecorationScreenState
    extends State<ThemeLayoutDecorationScreen> {
  Brightness _editingBrightness = Brightness.light;
  String _selectedSlot = 'home';
  String? _error;

  static const _slots = [
    ('home', '首页'),
    ('campus', '校园'),
    ('me', '我的'),
  ];

  @override
  void initState() {
    super.initState();
    _editingBrightness = context.read<ThemeProvider>().effectiveBrightness;
  }

  Future<String?> _pickAndAdopt(ThemeAssetKind kind) async {
    setState(() => _error = null);
    try {
      final rawPath = widget.pickImagePath != null
          ? await widget.pickImagePath!(kind)
          : (await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: kind == ThemeAssetKind.sticker
                  ? const ['png', 'webp']
                  : const ['png', 'jpg', 'jpeg', 'webp'],
              withData: false,
            ))
                ?.files
                .single
                .path;
      if (rawPath == null || !mounted) return null;
      return await context.read<ThemeProvider>().adoptDecorationImage(
            rawPath,
            kind,
          );
    } on ThemePackError catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
      return null;
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法读取所选图片，请重新选择符合尺寸要求的静态图片。');
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    final appearance = provider.appearance;
    final mode = _editingBrightness == Brightness.dark ? 'dark' : 'light';
    final previewTheme = appearance.buildTheme(_editingBrightness);

    final materialGroup = appearance.group(ThemeGroup.material);
    Map? rawCardStyleMap;
    if (materialGroup != null && materialGroup['legacy'] != true) {
      rawCardStyleMap = (materialGroup[mode] as Map?)?['cardStyle'] as Map?;
    }
    final rawCardStyle = rawCardStyleMap == null
        ? null
        : Map<String, dynamic>.from(rawCardStyleMap);

    final layoutGroup = appearance.group(ThemeGroup.layout);
    final rawSlotLayoutMap = (layoutGroup?['value'] as Map?)?[_selectedSlot] as Map?;
    final rawSlotLayout = rawSlotLayoutMap == null
        ? null
        : Map<String, dynamic>.from(rawSlotLayoutMap);
    final layoutSpec = ThemeHeaderLayoutSpec.fromMap(rawSlotLayout);

    final decoGroup = appearance.group(ThemeGroup.decoration);
    final rawSlotDecoMap = (decoGroup?[mode] as Map?)?[_selectedSlot] as Map?;
    final rawSlotDeco = rawSlotDecoMap == null
        ? null
        : Map<String, dynamic>.from(rawSlotDecoMap);

    final slotLabel =
        _slots.firstWhere((e) => e.$1 == _selectedSlot).$2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('布局与页头装饰'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<Brightness>(
                segments: const [
                  ButtonSegment(
                    value: Brightness.light,
                    label: Text('浅色模式参数'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: Brightness.dark,
                    label: Text('深色模式参数'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {_editingBrightness},
                onSelectionChanged: (v) =>
                    setState(() => _editingBrightness = v.single),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppCardSurface(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Text('实时组件预览', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ThemePresentationOverride(
                appearance: appearance,
                brightnessOverride: _editingBrightness,
                assetResolver: (p) => p.isEmpty ? null : FileImage(File(p)),
                child: Theme(
                  data: previewTheme,
                  child: Builder(
                    builder: (previewCtx) {
                      final tokens = AppThemeTokens.of(previewCtx);
                      final shape = AppShape.of(previewCtx);
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tokens.background,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: tokens.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_selectedSlot == 'home')
                              const HomeThemedHeaderBanner(feedModeLabel: '综合')
                            else if (_selectedSlot == 'campus')
                              CampusHeader(
                                semester: '2026—2027学年 · 第一学期',
                                date: DateTime(2026, 10, 18),
                              )
                            else
                              _MePreviewHeader(tokens: tokens, shape: shape),
                            const SizedBox(height: 10),
                            AppCardSurface(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: tokens.card,
                                borderRadius: BorderRadius.circular(shape.md),
                                border: Border.all(color: tokens.cardBorder),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '内容卡片示例',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: tokens.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '描边颜色读取 cardBorder，圆角由全局圆角档位控制。',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: tokens.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AppCardSurface(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppThemeTokens.of(context).card,
                  borderRadius: BorderRadius.circular(AppShape.of(context).lg),
                  border: Border.all(color: AppThemeTokens.of(context).cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '内容卡片样式',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (rawCardStyle != null)
                          TextButton(
                            onPressed: () => provider.updateCardStyle(
                              _editingBrightness,
                              null,
                            ),
                            child: const Text('重置当前明暗卡片样式'),
                          ),
                      ],
                    ),
                    ThemeCardStyleEditor(
                      cardStyle: rawCardStyle,
                      onChanged: (next) =>
                          provider.updateCardStyle(_editingBrightness, next),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in _slots)
                    ChoiceChip(
                      label: Text('${item.$2}页头'),
                      selected: _selectedSlot == item.$1,
                      onSelected: (_) =>
                          setState(() => _selectedSlot = item.$1),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              AppCardSurface(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppThemeTokens.of(context).card,
                  borderRadius: BorderRadius.circular(AppShape.of(context).lg),
                  border: Border.all(color: AppThemeTokens.of(context).cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ThemeHeaderLayoutEditor(
                      slotLabel: slotLabel,
                      rawLayout: rawSlotLayout,
                      onChanged: (next) =>
                          provider.updateHeaderLayout(_selectedSlot, next),
                    ),
                    if (layoutGroup != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () =>
                              provider.resetAppearanceGroup(ThemeGroup.layout),
                          child: const Text('重置全部页头布局'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              AppCardSurface(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppThemeTokens.of(context).card,
                  borderRadius: BorderRadius.circular(AppShape.of(context).lg),
                  border: Border.all(color: AppThemeTokens.of(context).cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ThemeHeaderDecorationEditor(
                      slot: _selectedSlot,
                      slotLabel: slotLabel,
                      layoutSpec: layoutSpec,
                      decoration: rawSlotDeco,
                      assetResolver: (p) =>
                          p.isEmpty ? null : FileImage(File(p)),
                      onPickHeaderBackground: () =>
                          _pickAndAdopt(ThemeAssetKind.header),
                      onPickSticker: () =>
                          _pickAndAdopt(ThemeAssetKind.sticker),
                      onChanged: (next) => provider.updateHeaderDecoration(
                        _editingBrightness,
                        _selectedSlot,
                        next,
                      ),
                    ),
                    if (decoGroup != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => provider.resetAppearanceGroup(
                            ThemeGroup.decoration,
                          ),
                          child: const Text('重置全部页头装饰'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MePreviewHeader extends StatelessWidget {
  const _MePreviewHeader({
    required this.tokens,
    required this.shape,
  });

  final AppThemeTokens tokens;
  final AppShape shape;

  @override
  Widget build(BuildContext context) {
    Widget buildCard(ThemeHeaderLayoutSpec layout, {required bool compact}) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: compact ? 10 : 14,
        ),
        decoration: BoxDecoration(
          color: tokens.card,
          borderRadius: BorderRadius.circular(shape.lg),
          border: Border.all(color: tokens.cardBorder),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: compact ? 20 : 26,
              backgroundColor: tokens.primaryContainer,
              child: Icon(Icons.person_rounded, color: tokens.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: layout.crossAxisAlignment,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '沈理同学',
                    textAlign: layout.textAlign,
                    style: TextStyle(
                      fontSize: compact ? 15 : 18,
                      fontWeight: FontWeight.w700,
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '信息科学与工程学院 · 诚信 100%',
                    textAlign: layout.textAlign,
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ThemeHeaderFrame(
      slot: 'me',
      defaultBuilder: (_) =>
          buildCard(const ThemeHeaderLayoutSpec(), compact: false),
      standardInfoBuilder: (_, layout) => buildCard(layout, compact: false),
      compactInfoBuilder: (_, layout) => buildCard(layout, compact: true),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12.5)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

const Object _unchanged = Object();
