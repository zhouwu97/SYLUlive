import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' show Document, Element;

import 'erke_models.dart';

/// 页面结构变化异常 — 必需节点缺失或值无法解析时抛出
class ErkePageChangedException implements Exception {
  final String message;
  final String? missingElementId;
  const ErkePageChangedException(this.message, {this.missingElementId});
  @override
  String toString() => 'ErkePageChangedException: $message'
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

  /// 按 ID 查找元素（精确 ID 优先，后缀匹配兜底）
  static Element? _findByIdOrSuffix(Document doc, String id) {
    final exact = doc.getElementById(id);
    if (exact != null) return exact;
    // ASP.NET ClientID 后缀匹配
    final elements = doc.querySelectorAll('[id\$="$id"]');
    if (elements.length == 1) return elements.first;
    if (elements.length > 1) {
      throw ErkePageChangedException(
        '多个元素匹配 #$id 后缀，无法确定唯一节点',
        missingElementId: id,
      );
    }
    return null;
  }

  /// 按精确 ID 从文档中提取 span 文本，并解析为 double
  /// 找不到节点或值非数字时抛 ErkePageChangedException
  /// 支持 ASP.NET ClientID 前缀（ctl00_..._CountA1）
  static double _requireSpanValue(Document doc, String id) {
    final el = _findByIdOrSuffix(doc, id);
    if (el == null) {
      throw ErkePageChangedException(
        '缺少必要元素: #$id',
        missingElementId: id,
      );
    }
    final text =
        (el.text.isNotEmpty ? el.text : el.attributes['value'] ?? '').trim();
    final value = double.tryParse(text);
    if (value == null || text.isEmpty) {
      throw ErkePageChangedException(
        '无法解析 #$id 的值: "$text"',
        missingElementId: id,
      );
    }
    return value;
  }

  /// 检查页面是否包含成绩数据（CountA1 非空）
  static bool _hasScoreData(Document doc) {
    for (final code in ['A', 'B', 'C', 'D', 'E']) {
      final el = _findByIdOrSuffix(doc, 'Count${code}1');
      if (el != null) {
        final text =
            (el.text.isNotEmpty ? el.text : el.attributes['value'] ?? '')
                .trim();
        if (text.isNotEmpty && double.tryParse(text) != null) return true;
      }
    }
    return false;
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

    // 官方总分节点作为权威数据
    final officialRequiredTotal = _requireSpanValue(doc, 'SunCount');
    final officialEarnedTotal = _requireSpanValue(doc, 'SunCount1');

    // 分类合计仅用于一致性检查
    if ((officialRequiredTotal - requiredTotal).abs() > 0.1) {
      throw ErkePageChangedException(
        '总分要求不一致: SunCount=$officialRequiredTotal, 分类合计=$requiredTotal',
      );
    }

    final conclusion = _getSpanTextOr(doc, 'Status', '');

    final double rawTotalGap = officialEarnedTotal < officialRequiredTotal
        ? (officialRequiredTotal - officialEarnedTotal)
        : 0.0;
    final double categoryGap = categories.fold(0.0,
        (sum, c) => sum + (c.earned < c.required ? c.required - c.earned : 0));
    final double graduationGap =
        rawTotalGap > categoryGap ? rawTotalGap : categoryGap;
    final unmetCount = categories.where((c) => !c.meetsNumerically).length;

    return ErkeGraduationSummary(
      requiredTotal: officialRequiredTotal,
      earnedTotal: officialEarnedTotal,
      rawTotalGap: rawTotalGap,
      categoryGap: categoryGap,
      graduationGap: graduationGap,
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

    // 官方总分节点作为权威数据
    final officialRequiredTotal = _requireSpanValue(doc, 'SunCount');
    final officialYearEarnedTotal = _requireSpanValue(doc, 'SunCount1');
    final officialCumulativeTotal = _requireSpanValue(doc, 'CountTotalSum');

    // 分类合计仅用于一致性检查
    if ((officialRequiredTotal - requiredTotal).abs() > 0.1) {
      throw ErkePageChangedException(
        '学年总分要求不一致: SunCount=$officialRequiredTotal, 分类合计=$requiredTotal',
      );
    }

    final year = extractSelectedOption(doc, 'YearTime') ?? '';
    final availableYears = extractSelectOptions(doc, 'YearTime');

    final conclusion = _getSpanTextOr(doc, 'Status', '');

    final double rawYearGap = officialYearEarnedTotal < officialRequiredTotal
        ? (officialRequiredTotal - officialYearEarnedTotal)
        : 0.0;
    final double categoryGap = categories.fold(
        0.0,
        (sum, c) =>
            sum + (c.yearEarned < c.required ? c.required - c.yearEarned : 0));
    final double minimumGap =
        rawYearGap > categoryGap ? rawYearGap : categoryGap;

    return ErkeYearlySummary(
      year: year,
      availableYears: availableYears,
      requiredTotal: officialRequiredTotal,
      yearEarnedTotal: officialYearEarnedTotal,
      cumulativeTotal: officialCumulativeTotal,
      rawYearGap: rawYearGap,
      categoryGap: categoryGap,
      minimumGap: minimumGap,
      officialConclusion: conclusion,
      categories: categories,
    );
  }

  /// 提取学年页的 hidden inputs（供 WebForms 学年切换 POST 使用）
  static Map<String, String> extractYearlyHiddenInputs(String html) {
    return extractHiddenInputs(parse(html));
  }

  // ==================================================================
  //  学年查询表单解析（不要求页面已包含成绩）
  // ==================================================================

  /// 解析学年页面的查询表单结构（GET 初始返回或空模板）
  static YearPageForm parseYearPageForm(String html) {
    final doc = parse(html);

    final availableYears = extractSelectOptions(doc, 'YearTime');
    final selectedYear = extractSelectedOption(doc, 'YearTime') ?? '';
    final hiddenInputs = extractHiddenInputs(doc);

    // 尝试找到实际提交按钮
    String? submitButtonName;
    String? submitButtonValue;
    String? eventTarget;

    // 查找 id/name 含 "btn" 或 "query" 的按钮/input
    for (final el in doc.querySelectorAll(
        'input[type="submit"], button, input[type="button"]')) {
      final id = (el.attributes['id'] ?? '').toLowerCase();
      final name = (el.attributes['name'] ?? '').toLowerCase();
      if (id.contains('btn') ||
          id.contains('query') ||
          name.contains('btn') ||
          name.contains('query')) {
        submitButtonName = el.attributes['name'] ?? el.attributes['id'];
        submitButtonValue = el.attributes['value'];
        break;
      }
    }

    // 若没找到按钮，尝试使用 YearTime 作为 eventTarget
    if (submitButtonName == null && availableYears.isNotEmpty) {
      eventTarget = 'YearTime';
    }

    final hasScores = _hasScoreData(doc);
    final hasExactCountA1 = doc.getElementById('CountA1') != null;
    final hasSuffixCountA1 =
        !hasExactCountA1 && doc.querySelectorAll('[id\$="CountA1"]').isNotEmpty;

    print('[Erke] yearly GET selectedYear=$selectedYear');
    print('[Erke] yearly GET availableYears=${availableYears.join(",")}');
    print(
        '[Erke] yearly GET hasScores=$hasScores hasExactCountA1=$hasExactCountA1 hasSuffixCountA1=$hasSuffixCountA1');
    print(
        '[Erke] yearly GET submitButton=$submitButtonName eventTarget=$eventTarget');

    return YearPageForm(
      availableYears: availableYears,
      selectedYear: selectedYear,
      hiddenInputs: hiddenInputs,
      submitButtonName: submitButtonName,
      submitButtonValue: submitButtonValue,
      eventTarget: eventTarget,
    );
  }

  /// 检查学年页 GET 返回是否已包含成绩
  static bool yearlyPageHasScores(String html) {
    return _hasScoreData(parse(html));
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
