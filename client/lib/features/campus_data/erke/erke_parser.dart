import 'package:html/parser.dart' as html_parser;
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';

class ErkeParser {
  /// Parses the RSA Public Key Base64 string from the login page.
  static String parsePublicKey(String html) {
    final doc = html_parser.parse(html);
    final keyNode = doc.getElementById('pubKey');
    if (keyNode == null) {
      throw const ErkeDecodeException('未能在页面中找到 RSA 公钥');
    }
    return keyNode.attributes['value'] ?? '';
  }

  /// Parses hidden fields for login
  static Map<String, String> parseLoginHiddenFields(String html) {
    final doc = html_parser.parse(html);
    final viewState = doc.getElementById('__VIEWSTATE')?.attributes['value'] ?? '';
    final viewStateGen =
        doc.getElementById('__VIEWSTATEGENERATOR')?.attributes['value'] ?? '';

    if (viewState.isEmpty) {
      throw const ErkeDecodeException('未找到 __VIEWSTATE');
    }

    return {
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
    };
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

    double extract(String key) {
      final id = ids[key]!;
      final node = doc.getElementById(id);
      if (node == null) {
        throw ErkeDecodeException('成绩页面结构异常：缺少节点 $id');
      }
      final valStr = node.text.trim();
      final val = double.tryParse(valStr);
      if (val == null) {
        throw ErkeDecodeException('成绩页面结构异常：节点 $id 数值无法解析 ($valStr)');
      }
      return val;
    }

    return ErkeSummary(
      categoryA: extract('categoryA'),
      categoryB: extract('categoryB'),
      categoryC: extract('categoryC'),
      categoryD: extract('categoryD'),
      categoryE: extract('categoryE'),
      total: extract('total'),
    );
  }

  /// Parses the activities from a page
  static ErkeActivitiesPage parseActivities(String html) {
    final doc = html_parser.parse(html);

    var table = doc.getElementById('GridView1') ?? doc.getElementById('GV');
    
    // Fallback heuristic if no ID matches
    if (table == null) {
      final tables = doc.querySelectorAll('table');
      for (final t in tables) {
        final text = t.text;
        if (text.contains('活动名称') && text.contains('申请单位')) {
          table = t;
          break;
        }
      }
    }

    if (table == null) {
      // If table doesn't exist, it might be an empty page, but more likely a structure change
      throw const ErkeDecodeException('活动页面结构异常：未找到活动列表');
    }

    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) {
      throw const ErkeDecodeException('活动页面结构异常：列表无行');
    }

    final activities = <ErkeActivity>[];

    // Skip the first row (header) and last row (pager if exists)
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.className == 'Pager') {
        continue;
      }
      final cells = row.querySelectorAll('td');
      if (cells.length < 8) continue;

      activities.add(ErkeActivity(
        name: cells[0].text.trim(),
        organizer: cells[1].text.trim(),
        date: cells[2].text.trim(),
        category: cells[3].text.trim(),
        role: cells[4].text.trim(),
        participantCount: int.tryParse(cells[6].text.trim()) ?? 0,
        score: double.tryParse(cells[7].text.trim()) ?? 0.0,
      ));
    }

    final viewState = doc.getElementById('__VIEWSTATE')?.attributes['value'];
    
    // Check if there is a next page
    final nextBtn = doc.querySelector('a[href*="TPaged1\$GotoPage"]');
    bool hasNext = nextBtn != null;

    return ErkeActivitiesPage(
      activities: activities,
      hasNext: hasNext,
      nextViewState: viewState,
    );
  }
}
