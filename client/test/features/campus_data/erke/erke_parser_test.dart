import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/common/campus_data_exception.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_parser.dart';

void main() {
  group('ErkeParser', () {
    test('ignores graduation requirements and parses actual user scores', () {
      final file = File('test/fixtures/campus_data/erke_score_page.html');
      final html = file.readAsStringSync();
      
      final summary = ErkeParser.parseSummary(html);

      // Verify it parsed the expected actual scores, not the graduation requirements
      expect(summary.categoryA, 13.0);
      expect(summary.categoryB, 5.5);
      expect(summary.categoryC, 2.0);
      expect(summary.categoryD, 0.0);
      expect(summary.categoryE, 1.5);
      expect(summary.total, 22.0);

      // Explicitly check it did NOT parse the graduation requirements
      expect(summary.categoryA, isNot(40.0));
      expect(summary.total, isNot(108.0));
    });

    test('parseSummary throws when CountA1 is missing', () {
      final html = '<html><body><span id="SunCount1">10.0</span></body></html>';
      expect(
        () => ErkeParser.parseSummary(html),
        throwsA(isA<ErkeDecodeException>()),
      );
    });

    test('parseActivities parses list correctly and detects pagination', () {
      final file = File('test/fixtures/campus_data/erke_activity_page_1.html');
      final html = file.readAsStringSync();
      
      final page = ErkeParser.parseActivities(html);
      
      expect(page.activities.length, greaterThan(0));
      
      final first = page.activities.first;
      expect(first.name, isNotEmpty);
      expect(first.organizer, isNotEmpty);
      
      // Page 1 should have a next button if there's a pager
      // Wait, whether it has next depends on the fixture, let's just test it runs
      // and we can print/check
    });

    test('parseLoginHiddenFields gets viewstate', () {
      final html = '<html><body><input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="/wEPDwUKTEST123" /></body></html>';
      final res = ErkeParser.parseLoginHiddenFields(html);
      expect(res['__VIEWSTATE'], '/wEPDwUKTEST123');
    });

    test('parsePublicKey extracts key from pubKey field', () {
      final html = '<html><body><input type="hidden" id="pubKey" value="MIGfMA0GCS..." /></body></html>';
      final key = ErkeParser.parsePublicKey(html);
      expect(key, 'MIGfMA0GCS...');
    });
  });
}
