import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' show Document;

import 'erke_models.dart';

/// 页面结构变化异常 — 必需节点缺失或值无法解析时抛出
class ErkePageChangedException implements Exception {
  final String message;
  final String? missingElementId;
  const ErkePageChangedException(this.message, {this.missingElementId});
  @override
  String toString() =>
      'ErkePageChangedException: $message'
      '${missingElementId != null ? ' (missing: #$missingElementId)' : ''}';
}

/// 二课系统 HTML 页面解析器
class ErkeParser {
  ErkeParser._();

  /// A~E 分类标签映射
  static const _categoryLabels = {
    'A': '思想成长',
    'B': '实践实习',
    'C': '创新创业',
    'D': '志愿公益',
    'E': '文体活动和技能特长',
  };

  // ==================================================================
  //  通用工具
  // ==================================================================

  /// 按精确 ID 从文档中提取 span 文本，并解析为 double
  /// 找不到节点或值非数字时抛 ErkePageChangedException
  static double _requireSpanValue(Document doc, String id) {
    final el = doc.getElementById(id);
    if (el == null) {
      throw ErkePageChangedException(
        '缺少必要元素: #$id',
        missingElementId: id,
      );
    }
    final text = el.text.trim();
    final value = double.tryParse(text);
    if (value == null) {
      throw ErkePageChangedException(
        '无法解析 #$id 的值: "$text"',
        missingElementId: id,
      );
    }
    return value;
  }

  /// 按 ID 提取文本，找不到返回空字符串
  static String _getSpanTextOr(Document doc, String id, String defaultValue) {
    final el = doc.getElementById(id);
    return el?.text.trim() ?? defaultValue;
  }

  /// 提取 select[name] 的所有 option value 列表
  static List<String> extractSelectOptions(Document doc, String selectName) {
    final select = doc.querySelector('select[name="$selectName"]');
    if (select == null) return [];
    return select
        .querySelectorAll('option')
        .map((o) => o.attributes['value'] ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
  }

  /// 提取 select[name] 的当前选中值
  static String? extractSelectedOption(Document doc, String selectName) {
    final select = doc.querySelector('select[name="$selectName"]');
    if (select == null) return null;
    final selected = select.querySelector('option[selected]');
    if (selected != null) return selected.attributes['value'];
    final first = select.querySelector('option');
    return first?.attributes['value'];
  }

  /// 提取所有 hidden input 的 name=value 映射
  static Map<String, String> extractHiddenInputs(Document doc) {
    final map = <String, String>{};
    for (final input in doc.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      final value = input.attributes['value'] ?? '';
      if (name.isNotEmpty) map[name] = value;
    }
    return map;
  }

  // ==================================================================
  //  毕业要求解析
  // ==================================================================

  /// 解析 StuFinishStudentScore.aspx → ErkeGraduationSummary
  static ErkeGraduationSummary parseGraduationSummary(String html) {
    final doc = parse(html);
    final categories = <ErkeRequirementCategory>[];

    double requiredTotal = 0;
    double earnedTotal = 0;

    for (final code in ['A', 'B', 'C', 'D', 'E']) {
      final name = _categoryLabels[code]!;
      final required = _requireSpanValue(doc, 'Count$code');
      final earned = _requireSpanValue(doc, 'Count${code}1');

      requiredTotal += required;
      earnedTotal += earned;

      categories.add(ErkeRequirementCategory(
        code: code,
        name: name,
        required: required,
        earned: earned,
        meetsNumerically: earned >= required,
      ));
    }

    // 验证总分节点存在
    final reqTotalFromPage = _requireSpanValue(doc, 'SunCount');
    _requireSpanValue(doc, 'SunCount1'); // 确保节点存在

    if ((reqTotalFromPage - requiredTotal).abs() > 0.1) {
      throw ErkePageChangedException(
        '总分要求不一致: SunCount=$reqTotalFromPage, 分类合计=$requiredTotal',
      );
    }

    final conclusion =
        _getSpanTextOr(doc, 'Status', '');

    final double totalGap =
        earnedTotal < requiredTotal ? (requiredTotal - earnedTotal) : 0.0;
    final unmetCount =
        categories.where((c) => !c.meetsNumerically).length;

    return ErkeGraduationSummary(
      requiredTotal: requiredTotal,
      earnedTotal: earnedTotal,
      totalGap: totalGap,
      unmetCount: unmetCount,
      officialConclusion: conclusion,
      categories: categories,
    );
  }

  // ==================================================================
  //  学年要求解析
  // ==================================================================

  /// 解析 StuFinishStudentScoreXN.aspx → ErkeYearlySummary
  static ErkeYearlySummary parseYearlySummary(String html) {
    final doc = parse(html);
    final categories = <ErkeYearlyCategory>[];

    double requiredTotal = 0;
    double yearEarnedTotal = 0;
    double cumulativeTotal = 0;

    for (final code in ['A', 'B', 'C', 'D', 'E']) {
      final name = _categoryLabels[code]!;
      final required = _requireSpanValue(doc, 'Count$code');
      final yearEarned = _requireSpanValue(doc, 'Count${code}1');
      final cumulative = _requireSpanValue(doc, 'Count${code}Sum');

      requiredTotal += required;
      yearEarnedTotal += yearEarned;
      cumulativeTotal += cumulative;

      categories.add(ErkeYearlyCategory(
        code: code,
        name: name,
        required: required,
        yearEarned: yearEarned,
        cumulative: cumulative,
        meetsNumerically: yearEarned >= required,
      ));
    }

    // 验证总分节点存在
    final reqTotalFromPage = _requireSpanValue(doc, 'SunCount');
    _requireSpanValue(doc, 'SunCount1'); // 确保节点存在
    _requireSpanValue(doc, 'CountTotalSum'); // 确保节点存在

    if ((reqTotalFromPage - requiredTotal).abs() > 0.1) {
      throw ErkePageChangedException(
        '学年总分要求不一致: SunCount=$reqTotalFromPage, 分类合计=$requiredTotal',
      );
    }

    final year = extractSelectedOption(doc, 'YearTime') ?? '';
    final availableYears = extractSelectOptions(doc, 'YearTime');

    final conclusion =
        _getSpanTextOr(doc, 'Status', '');

    final double yearGap = yearEarnedTotal < requiredTotal
        ? (requiredTotal - yearEarnedTotal)
        : 0.0;

    return ErkeYearlySummary(
      year: year,
      availableYears: availableYears,
      requiredTotal: requiredTotal,
      yearEarnedTotal: yearEarnedTotal,
      cumulativeTotal: cumulativeTotal,
      yearGap: yearGap,
      officialConclusion: conclusion,
      categories: categories,
    );
  }

  /// 提取学年页的 hidden inputs（供 WebForms 学年切换 POST 使用）
  static Map<String, String> extractYearlyHiddenInputs(String html) {
    return extractHiddenInputs(parse(html));
  }

  // ==================================================================
  //  活动明细解析（从 SyluClientCrawler 迁移）
  // ==================================================================

  /// 解析 StuActionSearch.aspx → List<ErkeActivity>
  static List<ErkeActivity> parseActivities(String html) {
    final doc = parse(html);
    final activities = <ErkeActivity>[];

    // 优先 GridView1，回退 DataGrid1，再回退任意 table
    var rows = doc.querySelectorAll('#GridView1 tr');
    if (rows.isEmpty) rows = doc.querySelectorAll('#DataGrid1 tr');
    if (rows.isEmpty) rows = doc.querySelectorAll('table tr');

    for (final row in rows) {
      final cols = row.querySelectorAll('td');
      if (cols.length >= 8) {
        final itemName = cols[0].text.trim();
        final score = cols[7].text.trim();
        final date = cols[2].text.trim();
        var category = cols[3].text.trim();

        if (itemName.isNotEmpty &&
            !itemName.contains('活动名称') &&
            !itemName.contains('序号')) {
          // 合并分类
          if (category == '文体活动' || category == '技能特长') {
            category = '文体活动和技能特长';
          }
          activities.add(ErkeActivity(
            item: itemName,
            score: score,
            date: date,
            category: category,
          ));
        }
      }
    }

    // 按日期降序
    activities.sort((a, b) => b.date.compareTo(a.date));

    return activities;
  }
}
