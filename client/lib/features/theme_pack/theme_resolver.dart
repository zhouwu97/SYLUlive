import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../theme/app_palette.dart';
import 'theme_contrast.dart';

/// 主题工坊推导与对比度自动修正（契约第 4、5 节），仅在 Dart 端实现。
abstract final class ThemeResolver {
  static const translucentTokens = {
    'cardBorder',
    'divider',
    'outline',
    'navBackground',
    'appBarBackground',
    'timetableGrid',
    'timetableToday',
  };

  static String formatHex(Color color, {bool allowAlpha = false}) {
    final argb = color.toARGB32();
    final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    if (!allowAlpha || hex.startsWith('FF')) {
      return '#${hex.substring(2)}';
    }
    return '#$hex';
  }

  static Color? tryParseHex(String raw, {bool allowAlpha = false}) {
    final trimmed = raw.trim();
    final normalized = trimmed.startsWith('#') ? trimmed : '#$trimmed';
    final pattern = allowAlpha
        ? RegExp(r'^#(?:[a-fA-F0-9]{6}|[a-fA-F0-9]{8})$')
        : RegExp(r'^#[a-fA-F0-9]{6}$');
    if (!pattern.hasMatch(normalized)) return null;
    return ThemeContrast.parseColor(normalized.toUpperCase());
  }

  static DynamicSchemeVariant parseSchemeVariant(String? raw) {
    for (final v in DynamicSchemeVariant.values) {
      if (v.name == raw) return v;
    }
    return DynamicSchemeVariant.tonalSpot;
  }

  /// 按契约第 4 节从种子色与方案推导全部 36 个语义 Token；[overrides] 存在时优先覆盖。
  static Map<String, String> deriveTokens({
    required Color seedColor,
    required Brightness brightness,
    DynamicSchemeVariant schemeVariant = DynamicSchemeVariant.tonalSpot,
    Map<String, String> overrides = const {},
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      dynamicSchemeVariant: schemeVariant,
    );
    final isDark = brightness == Brightness.dark;
    final background = scheme.surface;
    Color blendOnBg(Color fg, double opacity) =>
        Color.alphaBlend(fg.withValues(alpha: opacity), background);

    final derived = <String, Color>{
      'primary': scheme.primary,
      'onPrimary': scheme.onPrimary,
      'primaryContainer': scheme.primaryContainer,
      'onPrimaryContainer': scheme.onPrimaryContainer,
      'background': background,
      'surface': scheme.surfaceContainerLow,
      'surfaceElevated':
          isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
      'surfaceMuted': scheme.surfaceContainerHighest,
      'card': isDark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
      'cardBorder': scheme.outlineVariant,
      'textPrimary': scheme.onSurface,
      'textSecondary': scheme.onSurfaceVariant,
      'textTertiary': blendOnBg(scheme.onSurfaceVariant, 0.75),
      'textDisabled': blendOnBg(scheme.onSurface, 0.38),
      'divider': scheme.outlineVariant,
      'outline': scheme.outline,
      'inputFill': scheme.surfaceContainerHighest,
      'inputFillFocused': scheme.surfaceContainerHigh,
      'searchFill': scheme.surfaceContainerHighest,
      'tagBackground': scheme.secondaryContainer,
      'tagText': scheme.onSecondaryContainer,
      'navBackground': scheme.surfaceContainer,
      'navSelected': scheme.primary,
      'navUnselected': scheme.onSurfaceVariant,
      'appBarBackground': background,
      'appBarForeground': scheme.onSurface,
      'bubbleIncoming': scheme.surfaceContainerHigh,
      'bubbleIncomingText': scheme.onSurface,
      'bubbleOutgoing': scheme.primaryContainer,
      'bubbleOutgoingText': scheme.onPrimaryContainer,
      'feedSectionSurface': scheme.secondaryContainer,
      'feedFeaturedSurface': scheme.tertiaryContainer,
      'feedFeaturedText': scheme.onTertiaryContainer,
      // 课程块文字与内置默认外观一致用白色，不参与硬性对比度检查。
      'courseCardText': const Color(0xFFFFFFFF),
      'timetableGrid': scheme.outlineVariant,
      'timetableToday': blendOnBg(scheme.primary, 0.12),
    };

    final result = <String, String>{
      for (final entry in derived.entries)
        entry.key: formatHex(
          entry.value,
          allowAlpha: translucentTokens.contains(entry.key),
        ),
    };
    for (final entry in overrides.entries) {
      if (result.containsKey(entry.key)) {
        result[entry.key] = entry.value.toUpperCase();
      }
    }
    return result;
  }

  /// 原版 UI 的课程五色（蓝、绿、紫、红、橙），没有主题配色时的标准。
  static List<String> originalCoursePalette(Brightness brightness) => [
        for (final color in AppPalette.defaults(brightness).coursePalette)
          formatHex(color),
      ];

  /// 跟随主题种子色的 6 色课程色板：从种子色相起每 60° 一档，
  /// 色调停在能托住白色课程文字的中间档，和原版五色的明度接近。
  static List<String> generateCoursePalette({
    required Color seedColor,
    required Brightness brightness,
  }) {
    final hue = Hct.fromInt(seedColor.toARGB32()).hue;
    final tone = brightness == Brightness.light ? 56.0 : 60.0;
    return [
      for (var i = 0; i < 6; i++)
        formatHex(Color(Hct.from((hue + i * 60.0) % 360.0, 52, tone).toInt())),
    ];
  }

  /// 保持 HCT 色相和色度不变，每次将色调移动 1 直至达到阈值；0 或 100 仍不达标则保留原色。
  static Color autoFixColorForContrast({
    required Color foreground,
    required Color background,
    required double threshold,
  }) {
    final alpha = foreground.a;
    double eval(Color candidate) {
      final composedFg = alpha < 1.0
          ? Color.alphaBlend(candidate.withValues(alpha: alpha), background)
          : candidate;
      return ThemeContrast.ratio(composedFg, background);
    }

    if (eval(foreground) >= threshold) return foreground;

    final hct = Hct.fromInt(foreground.withAlpha(0xFF).toARGB32());
    final hue = hct.hue;
    final chroma = hct.chroma;
    final startTone = hct.tone.round().clamp(0, 100);
    final preferDarker = background.computeLuminance() > 0.5;
    final directions = preferDarker ? const [-1, 1] : const [1, -1];

    for (final step in directions) {
      var tone = startTone;
      while (true) {
        tone += step;
        if (tone < 0 || tone > 100) break;
        final nextRgb = Color(Hct.from(hue, chroma, tone.toDouble()).toInt());
        final candidate =
            alpha < 1.0 ? nextRgb.withValues(alpha: alpha) : nextRgb;
        if (eval(candidate) >= threshold) {
          return candidate;
        }
      }
    }
    return foreground;
  }

  /// 检查单个明暗变体的全部对比度项（契约第 5 节）。
  static List<ThemeContrastIssue> checkVariant({
    required Brightness brightness,
    required Map<String, String> tokens,
    required List<String> coursePalette,
  }) {
    final issues = <ThemeContrastIssue>[];
    final palette = AppPalette.fromJson(
      tokens,
      coursePalette: [
        for (final hex in coursePalette) ThemeContrast.parseColor(hex),
      ],
    );
    final colors = palette.tokenColors;
    void compare(
      String foreground,
      String background,
      double threshold, {
      Color? composed,
    }) {
      final base = composed ??
          Color.alphaBlend(colors[background]!, palette.background);
      final front = Color.alphaBlend(colors[foreground]!, base);
      final result = ThemeContrast.ratio(front, base);
      if (result < threshold) {
        issues.add(
          ThemeContrastIssue(
            brightness,
            foreground,
            background,
            result,
            threshold,
          ),
        );
      }
    }

    compare('textPrimary', 'background', 4.5);
    compare('textPrimary', 'card', 4.5);
    compare('textSecondary', 'card', 4.5);
    compare('onPrimary', 'primary', 4.5);
    compare('tagText', 'tagBackground', 4.5);
    compare('appBarForeground', 'appBarBackground', 4.5);
    compare('bubbleOutgoingText', 'bubbleOutgoing', 4.5);
    compare('navSelected', 'navBackground', 3.0);
    compare('navUnselected', 'navBackground', 3.0);
    return issues;
  }

  /// 对单个变体中不达标的对比度项执行自动修正，返回修正后的 tokens 与 coursePalette。
  static ({
    Map<String, String> tokens,
    List<String> coursePalette,
    Map<String, String> changedOverrides,
  }) autoFixVariant({
    required Brightness brightness,
    required Map<String, String> tokens,
    required List<String> coursePalette,
  }) {
    final nextTokens = Map<String, String>.from(tokens);
    final changed = <String, String>{};

    Color readToken(String key) => ThemeContrast.parseColor(nextTokens[key]!);
    Color effectiveBg(String key) =>
        Color.alphaBlend(readToken(key), readToken('background'));

    // textPrimary 需同时满足 background 与 card 两个背景的 4.5 阈值。
    {
      var fg = readToken('textPrimary');
      final bgA = effectiveBg('background');
      final bgB = effectiveBg('card');
      if (ThemeContrast.ratio(Color.alphaBlend(fg, bgA), bgA) < 4.5) {
        fg = autoFixColorForContrast(
          foreground: fg,
          background: bgA,
          threshold: 4.5,
        );
      }
      if (ThemeContrast.ratio(Color.alphaBlend(fg, bgB), bgB) < 4.5) {
        fg = autoFixColorForContrast(
          foreground: fg,
          background: bgB,
          threshold: 4.5,
        );
      }
      final hex = formatHex(fg);
      if (hex != nextTokens['textPrimary']) {
        nextTokens['textPrimary'] = hex;
        changed['textPrimary'] = hex;
      }
    }

    const pairs = [
      ('textSecondary', 'card', 4.5),
      ('onPrimary', 'primary', 4.5),
      ('tagText', 'tagBackground', 4.5),
      ('appBarForeground', 'appBarBackground', 4.5),
      ('bubbleOutgoingText', 'bubbleOutgoing', 4.5),
      ('navSelected', 'navBackground', 3.0),
      ('navUnselected', 'navBackground', 3.0),
    ];
    for (final (fgKey, bgKey, minRatio) in pairs) {
      final fg = readToken(fgKey);
      final bg = effectiveBg(bgKey);
      final fixed = autoFixColorForContrast(
        foreground: fg,
        background: bg,
        threshold: minRatio,
      );
      final hex = formatHex(
        fixed,
        allowAlpha: translucentTokens.contains(fgKey),
      );
      if (hex != nextTokens[fgKey]) {
        nextTokens[fgKey] = hex;
        changed[fgKey] = hex;
      }
    }

    return (
      tokens: nextTokens,
      coursePalette: coursePalette,
      changedOverrides: changed,
    );
  }
}

/// 主题工坊本机草稿存储（保存在 `<themesRoot>/drafts/<draftId>/`）。
class ThemeWorkshopDraftStore {
  ThemeWorkshopDraftStore({
    Directory? themesDirectory,
    this.writeHook,
  }) : _themesDirectory = themesDirectory;

  final Directory? _themesDirectory;
  final Future<void> Function(String draftId, Map<String, dynamic> data)?
      writeHook;

  Future<Directory> _draftsRoot() async {
    final base = _themesDirectory ??
        Directory(
          path.join((await getApplicationDocumentsDirectory()).path, 'themes'),
        );
    return Directory(path.join(base.path, 'drafts')).create(recursive: true);
  }

  Future<Directory> draftDirectory(String draftId) async {
    final root = await _draftsRoot();
    return Directory(path.join(root.path, draftId)).create(recursive: true);
  }

  Future<void> save(String draftId, Map<String, dynamic> data) async {
    if (writeHook != null) {
      await writeHook!(draftId, data);
    }
    final folder = await draftDirectory(draftId);
    final payload = <String, dynamic>{
      ...data,
      'draftId': draftId,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final tmp = File(path.join(folder.path, 'draft.json.tmp'));
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(path.join(folder.path, 'draft.json'));
  }

  Future<Map<String, dynamic>?> load(String draftId) async {
    final root = await _draftsRoot();
    final file = File(path.join(root.path, draftId, 'draft.json'));
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> list() async {
    final root = await _draftsRoot();
    final results = <Map<String, dynamic>>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(path.join(entity.path, 'draft.json'));
      if (!await file.exists()) continue;
      try {
        results.add(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    results.sort(
      (a, b) => ((b['updatedAt'] as String?) ?? '')
          .compareTo((a['updatedAt'] as String?) ?? ''),
    );
    return results;
  }

  Future<String> copyAssetIntoDraft(
    String draftId,
    String sourcePath,
    String targetSubpath,
  ) async {
    final folder = await draftDirectory(draftId);
    final dest = File(path.join(folder.path, 'assets', targetSubpath));
    await dest.parent.create(recursive: true);
    if (path.normalize(path.absolute(sourcePath)) !=
        path.normalize(path.absolute(dest.path))) {
      await File(sourcePath).copy(dest.path);
    }
    return dest.path;
  }

  Future<String> writeAssetBytes(
    String draftId,
    String targetSubpath,
    List<int> bytes,
  ) async {
    final folder = await draftDirectory(draftId);
    final dest = File(path.join(folder.path, 'assets', targetSubpath));
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }

  Future<void> delete(String draftId) async {
    final root = await _draftsRoot();
    final folder = Directory(path.join(root.path, draftId));
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }
}
