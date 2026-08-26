import 'package:flutter/widgets.dart';

final RegExp _postContentUrlPattern = RegExp(
  r'(?:(?:https?://)|(?:www\.))[^\s<>"\u0000-\u001F，。！？；：、（）【】]+',
  caseSensitive: false,
);

const _urlTrailingPunctuation = '.,!?;:)]}，。！？；：）】、';

final RegExp _emailPattern = RegExp(
  r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+",
);

final RegExp _numericPattern = RegExp(r'\d(?:[\d._:/-]*\d)?');
final RegExp _latinWordPattern = RegExp(
  r"[A-Za-z0-9]+(?:[_'-][A-Za-z0-9]+)*",
);

final RegExp _datePattern = RegExp(r'^\d{4}[-/]\d{1,2}[-/]\d{1,2}$');
final RegExp _timePattern = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');
final RegExp _phonePattern = RegExp(r'^(?:1[3-9]\d{9}|\d{3,4}-\d{7,8})$');
final RegExp _versionPattern = RegExp(r'^\d+(?:\.\d+){2,}$');
final RegExp _ipPattern = RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$');

/// 网址在正文中的位置和规范化后的打开地址。
class PostContentLink {
  final String text;
  final int start;
  final int end;
  final Uri uri;

  const PostContentLink({
    required this.text,
    required this.start,
    required this.end,
    required this.uri,
  });
}

/// 提取帖子/评论正文中的网页链接。
///
/// 这里是正文展示和智能选区共用的唯一 URL 解析入口，避免链接高亮和
/// 长按选区各自维护一套正则。`www.` 链接在打开时补充 https 协议。
List<PostContentLink> extractPostContentLinks(String text) {
  final links = <PostContentLink>[];
  for (final match in _postContentUrlPattern.allMatches(text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) continue;

    final linkText = _trimUrlTrailingPunctuation(raw);
    if (linkText.isEmpty) continue;
    final uri = parsePostContentUri(linkText);
    if (uri == null) continue;

    links.add(
      PostContentLink(
        text: linkText,
        start: match.start,
        end: match.start + linkText.length,
        uri: uri,
      ),
    );
  }
  return links;
}

/// 将正文中的 URL 字符串解析为可交给外部导航器的 URI。
Uri? parsePostContentUri(String value) {
  final candidate =
      value.toLowerCase().startsWith('www.') ? 'https://$value' : value;
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri;
}

String _trimUrlTrailingPunctuation(String value) {
  var end = value.length;
  while (end > 0 && _urlTrailingPunctuation.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}

/// 智能选区类型。
enum SmartSelectionKind {
  url,
  email,
  phone,
  number,
  numericSequence,
  date,
  time,
  ip,
  version,
  latinWord,
  identifier,
  cjkWord,
  grapheme,
  fallback,
}

/// 一个以 UTF-16 code unit 偏移表示的正文实体。
class SmartSelectionToken {
  final int start;
  final int end;
  final SmartSelectionKind kind;
  final String text;
  final Uri? uri;

  const SmartSelectionToken({
    required this.start,
    required this.end,
    required this.kind,
    required this.text,
    this.uri,
  });

  TextRange get range => TextRange(start: start, end: end);
}

/// 智能扩展后的选区结果。
class SmartSelectionResolution {
  final TextSelection selection;
  final SmartSelectionKind kind;
  final SmartSelectionToken? token;

  const SmartSelectionResolution({
    required this.selection,
    required this.kind,
    this.token,
  });

  String textInside(String text) => selection.textInside(text);

  bool get changed => token != null;
}

/// SYLUlive 正文专用的语义选词器。
///
/// 规则优先级固定为 URL、Email、数字类、英文/标识符、中文词语、grapheme，
/// 不依赖系统 PROCESS_TEXT，也不会把连续中文直接视为一个完整词语。
abstract final class SmartTextSelectionResolver {
  /// 将 Flutter 初始选区扩展为最合理的完整实体。
  ///
  /// [cjkWordBoundary] 是 Android ICU 返回的当前中文词边界。它只影响本次
  /// 解析，不会改变其他平台或其他输入框的行为。
  static SmartSelectionResolution resolveSelection(
    String text,
    TextSelection selection, {
    TextRange? cjkWordBoundary,
  }) {
    if (text.isEmpty || !selection.isValid) {
      return _fallbackResolution(selection);
    }

    final start = _clampOffset(selection.start, text.length);
    final end = _clampOffset(selection.end, text.length);
    final probes = _selectionProbes(selection, text.length);
    final tokens = _semanticTokens(text);

    for (final probe in probes) {
      final cjkToken = _cjkTokenAt(
        text,
        probe,
        platformBoundary: cjkWordBoundary,
      );
      if (cjkToken != null) tokens.add(cjkToken);
    }

    final candidates = tokens
        .where(
          (token) => selection.isCollapsed
              ? _containsOffset(token, probes)
              : _overlaps(token, start, end),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      return _fallbackResolution(selection);
    }

    final semanticCandidates = candidates
        .where((token) => token.kind != SmartSelectionKind.cjkWord)
        .toList(growable: false);
    SmartSelectionToken? token;
    if (selection.isCollapsed) {
      token = _pickHighestPriority(candidates);
    } else {
      // URL/Email/数字/英文必须包含 Flutter 原选区，避免拖动或已有的多词选区
      // 被意外缩小。中文由 ICU/回退分词负责纠正底层可能过大的整段选区。
      token = _pickHighestPriority(
        semanticCandidates
            .where((candidate) => _containsSelection(candidate, start, end))
            .followedBy(
              candidates.where(
                (candidate) =>
                    candidate.kind == SmartSelectionKind.cjkWord &&
                    _selectionIsCjk(text, start, end),
              ),
            )
            .toList(growable: false),
      );
    }

    if (token == null) return _fallbackResolution(selection);
    return SmartSelectionResolution(
      selection: _selectionForToken(selection, token),
      kind: token.kind,
      token: token,
    );
  }

  /// 解析某个点击/长按偏移所在的实体。
  static SmartSelectionToken? resolveTokenAt(
    String text,
    int offset, {
    TextRange? cjkWordBoundary,
  }) {
    if (text.isEmpty) return null;
    final probe = _clampOffset(offset, text.length);
    final tokens = _semanticTokens(text)
      ..addAll(
        [
          _cjkTokenAt(text, probe, platformBoundary: cjkWordBoundary),
          _graphemeTokenAt(text, probe),
        ].whereType<SmartSelectionToken>(),
      );
    return _pickHighestPriority(
      tokens.where((token) => _containsOffset(token, [probe])).toList(),
    );
  }

  /// 供组件判断是否需要向 Android ICU 请求中文边界。
  static bool isCjkAt(String text, int offset) {
    if (text.isEmpty) return false;
    final probe = _clampOffset(offset, text.length);
    final codeUnitIndex = probe == text.length ? probe - 1 : probe;
    if (codeUnitIndex < 0) return false;
    return _isCjkCodeUnit(text.codeUnitAt(codeUnitIndex));
  }

  /// 判断一个选中的字符串是否就是正文 URL。
  static bool isUrl(String value) {
    final trimmed = value.trim();
    final links = extractPostContentLinks(trimmed);
    return links.length == 1 && links.single.text == trimmed;
  }

  static List<SmartSelectionToken> _semanticTokens(String text) {
    final tokens = <SmartSelectionToken>[];

    for (final link in extractPostContentLinks(text)) {
      tokens.add(
        SmartSelectionToken(
          start: link.start,
          end: link.end,
          kind: SmartSelectionKind.url,
          text: link.text,
          uri: link.uri,
        ),
      );
    }

    for (final match in _emailPattern.allMatches(text)) {
      final value = match.group(0);
      if (value == null || value.isEmpty) continue;
      final trimmed = _trimEntityTrailingPunctuation(value);
      if (trimmed.isEmpty ||
          !_hasEntityBoundaries(text, match.start, match.end)) {
        continue;
      }
      tokens.add(
        SmartSelectionToken(
          start: match.start,
          end: match.start + trimmed.length,
          kind: SmartSelectionKind.email,
          text: trimmed,
        ),
      );
    }

    for (final match in _numericPattern.allMatches(text)) {
      final value = match.group(0);
      if (value == null || value.isEmpty) continue;
      if (!_hasNumericBoundaries(text, match.start, match.end, value)) {
        continue;
      }
      final digitCount = RegExp(r'\d').allMatches(value).length;
      if (digitCount < 2) continue;
      tokens.add(
        SmartSelectionToken(
          start: match.start,
          end: match.end,
          kind: _numericKind(value),
          text: value,
        ),
      );
    }

    for (final match in _latinWordPattern.allMatches(text)) {
      final value = match.group(0);
      if (value == null || value.isEmpty) continue;
      tokens.add(
        SmartSelectionToken(
          start: match.start,
          end: match.end,
          kind: value.contains(RegExp(r"[_'-]"))
              ? SmartSelectionKind.identifier
              : SmartSelectionKind.latinWord,
          text: value,
        ),
      );
    }

    return tokens;
  }

  static SmartSelectionKind _numericKind(String value) {
    if (_phonePattern.hasMatch(value)) return SmartSelectionKind.phone;
    if (_datePattern.hasMatch(value)) return SmartSelectionKind.date;
    if (_timePattern.hasMatch(value)) return SmartSelectionKind.time;
    if (_ipPattern.hasMatch(value) && _isValidIpv4(value)) {
      return SmartSelectionKind.ip;
    }
    if (_versionPattern.hasMatch(value)) return SmartSelectionKind.version;
    if (RegExp(r'^\d+$').hasMatch(value)) return SmartSelectionKind.number;
    return SmartSelectionKind.numericSequence;
  }

  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }
    return true;
  }

  static SmartSelectionToken? _cjkTokenAt(
    String text,
    int offset, {
    TextRange? platformBoundary,
  }) {
    if (!isCjkAt(text, offset)) return null;

    if (platformBoundary != null &&
        platformBoundary.isValid &&
        platformBoundary.start >= 0 &&
        platformBoundary.end <= text.length &&
        platformBoundary.start < platformBoundary.end &&
        platformBoundary.start <= offset &&
        platformBoundary.end >= offset &&
        _selectionIsCjk(text, platformBoundary.start, platformBoundary.end)) {
      return SmartSelectionToken(
        start: platformBoundary.start,
        end: platformBoundary.end,
        kind: SmartSelectionKind.cjkWord,
        text: text.substring(platformBoundary.start, platformBoundary.end),
      );
    }

    final codeUnitIndex = offset == text.length ? offset - 1 : offset;
    if (codeUnitIndex < 0 || !_isCjkCodeUnit(text.codeUnitAt(codeUnitIndex))) {
      return null;
    }
    final runStart = _cjkRunStart(text, codeUnitIndex);
    final runEnd = _cjkRunEnd(text, codeUnitIndex);

    SmartSelectionToken? bestDictionaryToken;
    for (final word in _commonCjkWords) {
      var searchFrom = runStart;
      while (searchFrom < runEnd) {
        final found = text.indexOf(word, searchFrom);
        if (found < runStart || found + word.length > runEnd) break;
        if (found <= codeUnitIndex && found + word.length > codeUnitIndex) {
          final candidate = SmartSelectionToken(
            start: found,
            end: found + word.length,
            kind: SmartSelectionKind.cjkWord,
            text: word,
          );
          if (bestDictionaryToken == null ||
              candidate.end - candidate.start >
                  bestDictionaryToken.end - bestDictionaryToken.start) {
            bestDictionaryToken = candidate;
          }
        }
        searchFrom = found + word.length;
      }
    }
    if (bestDictionaryToken != null) return bestDictionaryToken;

    if (runEnd - runStart == 1) {
      return SmartSelectionToken(
        start: runStart,
        end: runEnd,
        kind: SmartSelectionKind.cjkWord,
        text: text.substring(runStart, runEnd),
      );
    }

    // Dart/桌面端回退不把整段连续汉字作为一个词；用相邻双字保持可用的
    // 选择手感，Android API 24+ 会在同一次长按中用 ICU 结果替换它。
    final start =
        codeUnitIndex + 1 < runEnd ? codeUnitIndex : codeUnitIndex - 1;
    return SmartSelectionToken(
      start: start,
      end: start + 2,
      kind: SmartSelectionKind.cjkWord,
      text: text.substring(start, start + 2),
    );
  }

  static SmartSelectionToken? _graphemeTokenAt(String text, int offset) {
    if (text.isEmpty) return null;
    var cursor = 0;
    for (final grapheme in text.characters) {
      final end = cursor + grapheme.length;
      if (cursor <= offset && offset < end ||
          offset == end && end == text.length) {
        if (grapheme.trim().isEmpty) return null;
        return SmartSelectionToken(
          start: cursor,
          end: end,
          kind: SmartSelectionKind.grapheme,
          text: grapheme,
        );
      }
      cursor = end;
    }
    return null;
  }

  static SmartSelectionToken? _pickHighestPriority(
    List<SmartSelectionToken> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]..sort((a, b) {
        final priority = _priority(a.kind).compareTo(_priority(b.kind));
        if (priority != 0) return priority;
        final length = (b.end - b.start).compareTo(a.end - a.start);
        if (length != 0) return length;
        return a.start.compareTo(b.start);
      });
    return sorted.first;
  }

  static int _priority(SmartSelectionKind kind) {
    return switch (kind) {
      SmartSelectionKind.url => 0,
      SmartSelectionKind.email => 1,
      SmartSelectionKind.phone => 2,
      SmartSelectionKind.number ||
      SmartSelectionKind.numericSequence ||
      SmartSelectionKind.date ||
      SmartSelectionKind.time ||
      SmartSelectionKind.ip ||
      SmartSelectionKind.version =>
        3,
      SmartSelectionKind.latinWord || SmartSelectionKind.identifier => 4,
      SmartSelectionKind.cjkWord => 5,
      SmartSelectionKind.grapheme => 6,
      SmartSelectionKind.fallback => 7,
    };
  }

  static List<int> _selectionProbes(TextSelection selection, int textLength) {
    final probes = <int>{
      _clampOffset(selection.extentOffset, textLength),
      _clampOffset(selection.baseOffset, textLength),
      _clampOffset(selection.start, textLength),
      _clampOffset(selection.end == 0 ? 0 : selection.end - 1, textLength),
    };
    return probes.toList(growable: false);
  }

  static bool _containsOffset(SmartSelectionToken token, List<int> probes) {
    return probes.any(
      (probe) =>
          token.start <= probe && probe < token.end ||
          probe == token.end && token.end > token.start,
    );
  }

  static bool _containsSelection(
    SmartSelectionToken token,
    int start,
    int end,
  ) {
    return token.start <= start && token.end >= end;
  }

  static bool _overlaps(SmartSelectionToken token, int start, int end) {
    if (start == end) return _containsOffset(token, [start]);
    return token.start < end && token.end > start;
  }

  static TextSelection _selectionForToken(
    TextSelection source,
    SmartSelectionToken token,
  ) {
    final forward = source.baseOffset <= source.extentOffset;
    return TextSelection(
      baseOffset: forward ? token.start : token.end,
      extentOffset: forward ? token.end : token.start,
      affinity: source.affinity,
      isDirectional: source.isDirectional,
    );
  }

  static SmartSelectionResolution _fallbackResolution(
    TextSelection selection,
  ) {
    return SmartSelectionResolution(
      selection: selection,
      kind: SmartSelectionKind.fallback,
    );
  }

  static bool _selectionIsCjk(String text, int start, int end) {
    if (start < 0 || end > text.length || start >= end) return false;
    final value = text.substring(start, end);
    return value.isNotEmpty && value.runes.every(_isCjkCodePoint);
  }

  static bool _hasEntityBoundaries(String text, int start, int end) {
    final before = start == 0 ? null : text.codeUnitAt(start - 1);
    final after = end >= text.length ? null : text.codeUnitAt(end);
    return (before == null || !_isAsciiWordCodeUnit(before)) &&
        (after == null || !_isAsciiWordCodeUnit(after));
  }

  static bool _hasNumericBoundaries(
    String text,
    int start,
    int end,
    String value,
  ) {
    if (value.isEmpty || !_hasEntityBoundaries(text, start, end)) return false;
    // `gpt-5` / `foo_123` 属于英文标识符，不能被数字规则截断。
    if (start >= 2 && _isNumericConnector(text[start - 1])) {
      final beforeConnector = text.codeUnitAt(start - 2);
      if (_isAsciiWordCodeUnit(beforeConnector)) return false;
    }
    return true;
  }

  static String _trimEntityTrailingPunctuation(String value) {
    var end = value.length;
    while (end > 0 && _urlTrailingPunctuation.contains(value[end - 1])) {
      end--;
    }
    return value.substring(0, end);
  }

  static int _clampOffset(int value, int textLength) {
    if (value < 0) return 0;
    if (value > textLength) return textLength;
    return value;
  }

  static int _cjkRunStart(String text, int offset) {
    var start = offset;
    while (start > 0 && _isCjkCodeUnit(text.codeUnitAt(start - 1))) {
      start--;
    }
    return start;
  }

  static int _cjkRunEnd(String text, int offset) {
    var end = offset + 1;
    while (end < text.length && _isCjkCodeUnit(text.codeUnitAt(end))) {
      end++;
    }
    return end;
  }

  static bool _isNumericConnector(String value) {
    return value == '.' ||
        value == '_' ||
        value == ':' ||
        value == '/' ||
        value == '-';
  }

  static bool _isAsciiWordCodeUnit(int codeUnit) {
    return codeUnit >= 0x30 && codeUnit <= 0x39 ||
        codeUnit >= 0x41 && codeUnit <= 0x5A ||
        codeUnit >= 0x61 && codeUnit <= 0x7A ||
        codeUnit == 0x5F;
  }

  static bool _isCjkCodeUnit(int codeUnit) {
    return codeUnit >= 0x3400 && codeUnit <= 0x4DBF ||
        codeUnit >= 0x4E00 && codeUnit <= 0x9FFF ||
        codeUnit >= 0xF900 && codeUnit <= 0xFAFF;
  }

  static bool _isCjkCodePoint(int codePoint) {
    return codePoint >= 0x3400 && codePoint <= 0x4DBF ||
        codePoint >= 0x4E00 && codePoint <= 0x9FFF ||
        codePoint >= 0xF900 && codePoint <= 0xFAFF ||
        codePoint >= 0x20000 && codePoint <= 0x2FA1F;
  }
}

const _commonCjkWords = <String>[
  '沈阳理工大学',
  '校园生活',
  '普通文字',
  '最新版本',
  '欢迎访问',
  '注册',
  '问题',
  '最近',
  '发现',
  '很多人',
  '学号',
  '手机号',
  '电话号码',
  '打开',
  '网页',
  '链接',
  '网址',
  '版本',
  '评论',
  '帖子',
  '复制',
  '搜索',
  '分享',
  '全选',
  '账号',
  '登录',
  '系统',
  '内容',
  '中文',
  '文字',
];
