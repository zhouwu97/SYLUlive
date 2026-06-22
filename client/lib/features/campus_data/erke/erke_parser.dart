import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';

class ErkeParser {
  /// Parses the RSA Public Key Base64 string from the login page.
  static String parsePublicKey(String html) {
    final doc = html_parser.parse(html);
    final keyNode = doc.getElementById('pubKey');
    if (keyNode == null) {
      throw const ErkePageChangedException('未能找到 RSA 公钥');
    }
    return keyNode.attributes['value'] ?? '';
  }

  /// Parse all input[name] from the login form and find the captcha text
  static Map<String, String> parseLoginForm(String html) {
    final doc = html_parser.parse(html);
    final form = <String, String>{};

    for (final input in doc.querySelectorAll('form input[name]')) {
      final name = input.attributes['name']?.trim() ?? '';
      if (name.isEmpty) continue;

      final type = (input.attributes['type'] ?? 'text').toLowerCase();
      if (type == 'button' || type == 'reset' || type == 'file') continue;

      if (type == 'checkbox' || type == 'radio') {
        if (!input.attributes.containsKey('checked')) continue;
      }

      form[name] = input.attributes['value'] ?? '';
    }

    final viewState = doc.getElementById('__VIEWSTATE')?.attributes['value'] ?? '';
    if (viewState.isEmpty) {
      throw const ErkePageChangedException('未找到 __VIEWSTATE');
    }
    form['__VIEWSTATE'] = viewState;

    // Try to get captcha from the DOM
    var captcha = 'aaaa'; // Fallback
    final codeNodes = [
      doc.getElementById('code-box'),
      doc.querySelector('.code-img'),
      doc.querySelector('[id*="code-box"]'),
    ];
    
    for (final node in codeNodes) {
      if (node != null) {
        final text = node.text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
        if (text.length == 4) {
          captcha = text;
          break;
        }
      }
    }

    form['codeInput'] = captcha;
    return form;
  }

  /// Parses the actual user scores from the summary page, NOT the graduation requirements.
  static ErkeSummary parseSummary(String html) {
    final doc = html_parser.parse(html);

    final ids = {
      'categoryA': 'CountA1',
      'categoryB': 'CountB1',
      'categoryC': 'CountC1',
      'categoryD': 'CountD1',
      'categoryE': 'CountE1',
      'total': 'SunCount1',
    };

    double getScore(String key) {
      final id = ids[key]!;
      final node = doc.getElementById(id);
      if (node == null) {
        throw ErkePageChangedException('成绩页面结构异常：缺少节点 $id');
      }
      final valStr = node.text.trim();
      final val = double.tryParse(valStr);
      if (val == null) {
        throw ErkePageChangedException('成绩页面结构异常：节点 $id 数值无法解析 ($valStr)');
      }
      return val;
    }

    return ErkeSummary(
      categoryA: getScore('categoryA'),
      categoryB: getScore('categoryB'),
      categoryC: getScore('categoryC'),
      categoryD: getScore('categoryD'),
      categoryE: getScore('categoryE'),
      total: getScore('total'),
    );
  }

  /// Parses the activities from a page
  static ErkeActivitiesPage parseActivities(String html) {
    final doc = html_parser.parse(html);

    var table = doc.getElementById('GridView1');
    if (table == null) {
      // Try alternate heuristic for finding the activity table
      final allTables = doc.querySelectorAll('table');
      for (final t in allTables) {
        if (t.text.contains('活动项目名称') && t.text.contains('获取分数')) {
          table = t;
          break;
        }
      }
    }

    if (table == null) {
      // If table doesn't exist, it might be an empty page, but more likely a structure change
      throw const ErkePageChangedException('活动页面结构异常：未找到活动列表');
    }

    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) {
      throw const ErkePageChangedException('活动页面结构异常：列表无行');
    }

    final activities = <ErkeActivity>[];

    // Skip the first row (header) and last row (pager if exists)
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.className == 'Pager') {
        continue;
      }
      final columns = row.querySelectorAll('td');
      if (columns.length < 8) continue;

      var category = columns[3].text.trim();
      if (category == '技能特长') {
        category = '文体活动';
      }

      // Column 5 is participants, 7 is score
      final participantCount = int.tryParse(columns[5].text.replaceAll(',', '').trim());
      final score = double.tryParse(columns[7].text.replaceAll(',', '').trim());

      final activity = ErkeActivity(
        name: columns[0].text.trim(),
        organizer: columns[1].text.trim(),
        date: columns[2].text.trim(),
        category: category,
        role: columns[4].text.trim(),
        participantCount: participantCount ?? 0,
        score: score ?? 0.0,
      );

      if (activity.name.isNotEmpty && (activity.score != 0 || activity.date.isNotEmpty)) {
        activities.add(activity);
      }
    }

    // Extract pagination details
    int totalPages = 1;
    final pager = doc.getElementById('TPaged1');
    if (pager != null) {
      final fonts = pager.querySelectorAll('font');
      for (final font in fonts.reversed) {
        final val = int.tryParse(font.text.trim());
        if (val != null) {
          totalPages = val > totalPages ? val : totalPages;
          break;
        }
      }
      if (totalPages == 1) {
        final text = pager.text.replaceAll(RegExp(r'\s+'), '');
        final match = RegExp(r'(?:共|/|总页数[：:])(\d+)(?:页)?').firstMatch(text);
        if (match != null) {
          totalPages = int.tryParse(match.group(1)!) ?? 1;
        }
      }
    }
    totalPages = totalPages < 1 ? 1 : totalPages;

    final hiddenFields = <String, String>{};
    for (final hidden in ['__VIEWSTATE', '__VIEWSTATEGENERATOR', '__EVENTVALIDATION', '__VIEWSTATEENCRYPTED']) {
      final node = doc.getElementById(hidden);
      if (node != null) {
        hiddenFields[hidden] = node.attributes['value'] ?? '';
      }
    }

    return ErkeActivitiesPage(
      activities: activities,
      currentPage: 1, // Caller sets this properly if needed
      totalPages: totalPages,
      hiddenFields: hiddenFields,
    );
  }
}
