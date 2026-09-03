import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import '../model/grade_component.dart';
import '../model/grade_detail.dart';

/// 成绩详情解析器。
///
/// 严格迁移 Python 端的 parse_grade_detail_response 逻辑，
/// 兼容 JSON 和 HTML 表格两种响应格式。
abstract final class GradeDetailParser {
  /// 解析成绩详情响应。
  ///
  /// 先尝试解析为 JSON，如果不是 JSON 则解析为 HTML。
  static GradeDetail parse(String body, String courseName) {
    final text = body.trim();
    if (text.isEmpty) {
      return _emptyGradeDetail(courseName, '详情响应为空');
    }

    // 尝试 JSON
    final jsonPayload = _tryDecodeJson(text);
    if (jsonPayload != null) {
      final components = _parseGradeDetailJson(jsonPayload);
      final totalGrade = _findTotalGrade(components);
      return GradeDetail(
        success: components.isNotEmpty,
        courseName: courseName,
        totalGrade: totalGrade,
        components: components,
        message: components.isEmpty ? '详情 JSON 中没有成绩构成' : null,
      );
    }

    // 回退到 HTML
    final components = _parseGradeDetailHtml(text);
    final totalGrade = _findTotalGrade(components);
    return GradeDetail(
      success: components.isNotEmpty,
      courseName: courseName,
      totalGrade: totalGrade,
      components: components,
      message: components.isEmpty ? '详情 HTML 中没有成绩构成' : null,
    );
  }

  static GradeDetail _emptyGradeDetail(String courseName, String message) {
    return GradeDetail(
      success: false,
      courseName: courseName,
      totalGrade: '',
      components: const [],
      message: message,
    );
  }

  static Object? _tryDecodeJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// 从 JSON payload 解析成绩构成。
  ///
  /// 迁移 Python _parse_grade_detail_json。
  static List<GradeComponent> _parseGradeDetailJson(Object? payload) {
    final rows = <Map<String, dynamic>>[];

    if (payload is Map<String, dynamic>) {
      if (payload['items'] is List<dynamic>) {
        _addValidMaps(rows, payload['items'] as List<dynamic>);
      } else if (payload['rows'] is List<dynamic>) {
        _addValidMaps(rows, payload['rows'] as List<dynamic>);
      } else if (payload['data'] is List<dynamic>) {
        _addValidMaps(rows, payload['data'] as List<dynamic>);
      } else if (payload['data'] is Map<String, dynamic>) {
        return _parseGradeDetailJson(payload['data']);
      } else {
        // 降级：取第一个 List 类型的值
        for (final value in payload.values) {
          if (value is List<dynamic>) {
            _addValidMaps(rows, value);
            break;
          }
        }
      }
    } else if (payload is List<dynamic>) {
      _addValidMaps(rows, payload);
    }

    final components = <GradeComponent>[];
    for (final row in rows) {
      final name =
          _firstNonEmpty(row, ['cjxmmc', 'xmmc', 'xm', 'name', 'mc', 'cjfmc']);
      final score = _firstNonEmpty(
          row, ['cj', 'xmcj', 'score', 'df', 'cjz', 'kscj', 'bfzcj']);
      final weight =
          _firstNonEmpty(row, ['bl', 'xmbfb', 'cjxmbl', 'weight', 'qz', 'zb']);

      if (name.isEmpty || score.isEmpty) continue;

      components.add(GradeComponent(
        name: _normalizeComponentName(name),
        weight: weight.isEmpty ? null : weight,
        score: score,
      ));
    }

    return components;
  }

  /// 将列表中的有效 Map 元素添加到 rows。
  ///
  /// 严格复刻 Python：数组元素不是 dict 时直接跳过。
  static void _addValidMaps(
    List<Map<String, dynamic>> rows,
    List<dynamic> items,
  ) {
    for (final item in items) {
      if (item is Map<String, dynamic>) {
        rows.add(item);
      } else if (item is Map) {
        // 处理 Map<dynamic, dynamic> 等情况
        try {
          final converted = Map<String, dynamic>.from(item);
          rows.add(converted);
        } catch (_) {
          // 转换失败，跳过
        }
      }
      // 其他类型（null、字符串、数字等）直接跳过
    }
  }

  /// 从 HTML 解析成绩构成。
  ///
  /// 迁移 Python _parse_grade_detail_html。
  static List<GradeComponent> _parseGradeDetailHtml(String htmlText) {
    final document = html_parser.parse(htmlText);
    final components = <GradeComponent>[];

    for (final table in document.querySelectorAll('table')) {
      final headerCells = table
          .querySelectorAll('tr th, tr td')
          .take(8)
          .map((cell) => _normalizeText(cell.text))
          .toList();
      final headerText = headerCells.join(' ');

      if (!headerText.contains('成绩分项') &&
          !headerText.contains('分项比例') &&
          !headerText.contains('成绩')) {
        continue;
      }

      for (final tr in table.querySelectorAll('tr')) {
        var cells = tr
            .querySelectorAll('td')
            .map((td) => _normalizeText(td.text))
            .where((cell) => cell.isNotEmpty)
            .toList();

        if (cells.length < 2) continue;
        if (cells[0].contains('成绩分项') || cells[0].contains('分项名称')) {
          continue;
        }

        final String name;
        final String? weight;
        final String score;

        if (cells.length >= 3) {
          name = cells[0];
          weight = cells[1];
          score = cells[2];
        } else {
          name = cells[0];
          weight = null;
          score = cells[1];
        }

        if (name.isNotEmpty && score.isNotEmpty) {
          components.add(GradeComponent(
            name: _normalizeComponentName(name),
            weight: weight?.isEmpty == true ? null : weight,
            score: score,
          ));
        }
      }
    }

    return components;
  }

  static String _firstNonEmpty(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value != null) {
        final text = value.toString().trim();
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  static String _findTotalGrade(List<GradeComponent> components) {
    for (final component in components) {
      if (component.name.contains('总')) {
        return component.score;
      }
    }
    return components.isNotEmpty ? components.last.score : '';
  }

  static String _normalizeText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _normalizeComponentName(String value) {
    final text = _normalizeText(value);
    return text
        .replaceAll(RegExp(r'^[【\[\]】\s]+'), '')
        .replaceAll(RegExp(r'[【\[\]】\s]+$'), '')
        .trim();
  }
}
