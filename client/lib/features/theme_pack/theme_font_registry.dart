import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../platform/contracts/preferences_store.dart';
import 'theme_appearance.dart';
import 'theme_manifest.dart';

/// 管理自定义主题字体的校验试加载、冷启动首帧预加载与运行时 FontLoader 注册。
abstract final class ThemeFontRegistry {
  static final Set<String> _loadedFamilies = <String>{};
  static final Map<String, Future<String?>> _inflight =
      <String, Future<String?>>{};
  static int _probeCounter = 0;

  static String? familyForGroup(Map<String, dynamic>? fontGroup) {
    if (fontGroup == null) return null;
    final regular = fontGroup['regular'] as String?;
    if (regular == null || regular.isEmpty) return null;
    final source = fontGroup['source'] as Map?;
    if (source != null &&
        source['themeId'] is String &&
        source['version'] is int) {
      return 'theme_font_${source['themeId']}_${source['version']}';
    }
    final explicitKey = fontGroup['familyKey'] as String?;
    if (explicitKey != null && explicitKey.isNotEmpty) {
      return explicitKey;
    }
    final bold = fontGroup['bold'] as String? ?? '';
    return 'theme_font_local_${Object.hash(regular, bold).abs()}';
  }

  static String? resolvedFamilyFor(Map<String, dynamic>? fontGroup) {
    final family = familyForGroup(fontGroup);
    if (family == null || !_loadedFamilies.contains(family)) return null;
    return family;
  }

  /// 字体组里的标题字体（font.title）换算成可单独注册的字体描述。
  static Map<String, dynamic>? titleGroupFor(Map<String, dynamic>? fontGroup) {
    final title = fontGroup?['title'] as Map?;
    final regular = title?['regular'] as String?;
    if (regular == null || regular.isEmpty) return null;
    final source = fontGroup!['source'] as Map?;
    final key = source != null &&
            source['themeId'] is String &&
            source['version'] is int
        ? 'theme_title_${source['themeId']}_${source['version']}'
        : 'theme_title_local_${regular.hashCode.abs()}';
    return {'regular': regular, 'familyKey': key};
  }

  static String? resolvedTitleFamilyFor(Map<String, dynamic>? fontGroup) =>
      resolvedFamilyFor(titleGroupFor(fontGroup));

  static void debugResetForTesting() {
    _loadedFamilies.clear();
    _inflight.clear();
  }

  /// 在导入/解码边界试加载字体，捕获表结构缺失或引擎无法解析的损坏字体。
  static Future<void> probePackFont(
    ThemeManifest manifest,
    Map<String, Uint8List> contents,
  ) async {
    final font = manifest.data['font'] as Map?;
    if (font == null) return;
    final titlePath = (font['title'] as Map?)?['regular'] as String?;
    if (titlePath != null) {
      final titleBytes = contents[titlePath];
      if (titleBytes == null || !_hasRequiredSfntTables(titleBytes)) {
        throw ThemePackError('theme_font_invalid', titlePath);
      }
      try {
        await (FontLoader('theme_title_probe_${++_probeCounter}')
              ..addFont(
                  Future<ByteData>.value(ByteData.sublistView(titleBytes))))
            .load();
      } catch (_) {
        throw ThemePackError('theme_font_invalid', titlePath);
      }
    }
    final regularPath = font['regular'] as String?;
    if (regularPath == null) return;
    final boldPath = font['bold'] as String?;

    final regularBytes = contents[regularPath];
    if (regularBytes == null || !_hasRequiredSfntTables(regularBytes)) {
      throw ThemePackError('theme_font_invalid', regularPath);
    }
    Uint8List? boldBytes;
    if (boldPath != null) {
      boldBytes = contents[boldPath];
      if (boldBytes == null || !_hasRequiredSfntTables(boldBytes)) {
        throw ThemePackError('theme_font_invalid', boldPath);
      }
    }

    final probeFamily = 'theme_font_probe_${++_probeCounter}';
    try {
      final regularLoader = FontLoader(probeFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(regularBytes)));
      await regularLoader.load();
    } catch (_) {
      throw ThemePackError('theme_font_invalid', regularPath);
    }

    if (boldPath != null && boldBytes != null) {
      try {
        final boldLoader = FontLoader('${probeFamily}_bold')
          ..addFont(Future<ByteData>.value(ByteData.sublistView(boldBytes)));
        await boldLoader.load();
      } catch (_) {
        throw ThemePackError('theme_font_invalid', boldPath);
      }
    }
  }

  static bool _hasRequiredSfntTables(Uint8List bytes) {
    if (bytes.length < 12) return false;
    final data = ByteData.sublistView(bytes);
    final sfntVersion = data.getUint32(0);
    if (sfntVersion != 0x00010000 && sfntVersion != 0x4f54544f) return false;
    final numTables = data.getUint16(4);
    if (numTables == 0 || 12 + numTables * 16 > bytes.length) return false;

    final tags = <String>{};
    for (var i = 0; i < numTables; i++) {
      final entryOffset = 12 + i * 16;
      final tag = ascii.decode(
        bytes.sublist(entryOffset, entryOffset + 4),
        allowInvalid: true,
      );
      final tableOffset = data.getUint32(entryOffset + 8);
      final tableLength = data.getUint32(entryOffset + 12);
      if (tableOffset + tableLength > bytes.length || tableLength == 0) {
        if (const {'cmap', 'head', 'hhea', 'maxp', 'name'}.contains(tag)) {
          return false;
        }
      }
      tags.add(tag);
    }
    const coreRequired = {'cmap', 'head', 'hhea', 'maxp', 'name'};
    if (!tags.containsAll(coreRequired)) return false;
    final hasOutlines =
        tags.contains('glyf') || tags.contains('CFF ') || tags.contains('CFF2');
    return hasOutlines;
  }

  /// 加载正文字体和标题字体；返回正文字体家族名，只有标题字体时返回标题字体家族名。
  static Future<String?> ensureLoaded(
    Map<String, dynamic>? fontGroup, {
    Map<String, Uint8List>? inMemoryContents,
  }) async {
    final title = titleGroupFor(fontGroup);
    final titleFamily = title == null
        ? null
        : await _ensureSingle(title, inMemoryContents: inMemoryContents);
    final body =
        await _ensureSingle(fontGroup, inMemoryContents: inMemoryContents);
    return body ?? titleFamily;
  }

  static Future<String?> _ensureSingle(
    Map<String, dynamic>? fontGroup, {
    Map<String, Uint8List>? inMemoryContents,
  }) {
    final family = familyForGroup(fontGroup);
    if (family == null) return Future<String?>.value(null);
    if (_loadedFamilies.contains(family)) return Future<String?>.value(family);
    final existing = _inflight[family];
    if (existing != null) return existing;

    final task = _loadInternal(
      family: family,
      regularPath: fontGroup!['regular'] as String,
      boldPath: fontGroup['bold'] as String?,
      inMemoryContents: inMemoryContents,
    );
    _inflight[family] = task;
    return task.whenComplete(() => _inflight.remove(family));
  }

  static Future<String?> _loadInternal({
    required String family,
    required String regularPath,
    required String? boldPath,
    required Map<String, Uint8List>? inMemoryContents,
  }) async {
    try {
      final regularBytes = await _readFontBytes(regularPath, inMemoryContents);
      if (regularBytes == null || !_hasRequiredSfntTables(regularBytes)) {
        return null;
      }
      final loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(regularBytes)));
      if (boldPath != null && boldPath.isNotEmpty) {
        final boldBytes = await _readFontBytes(boldPath, inMemoryContents);
        if (boldBytes != null && _hasRequiredSfntTables(boldBytes)) {
          loader.addFont(
            Future<ByteData>.value(ByteData.sublistView(boldBytes)),
          );
        }
      }
      await loader.load();
      _loadedFamilies.add(family);
      return family;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _readFontBytes(
    String rawPath,
    Map<String, Uint8List>? inMemoryContents,
  ) async {
    if (inMemoryContents != null) {
      final normalized =
          rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
      final mem = inMemoryContents[rawPath] ?? inMemoryContents[normalized];
      if (mem != null) return mem;
    }
    final file = File(rawPath);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  static Future<void> preloadFromPreferences(
    AppPreferencesStore prefs, {
    required String appearanceKey,
  }) async {
    final raw = prefs.getString(appearanceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final appearance = ThemeAppearance(decoded);
      await ensureLoaded(appearance.group(ThemeGroup.font));
    } catch (_) {}
  }
}
