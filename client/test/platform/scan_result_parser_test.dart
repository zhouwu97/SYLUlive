import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/scan/scan_result_parser.dart';

void main() {
  group('ScanResultParser', () {
    test('解析竞赛详情协议', () {
      final result = ScanResultParser.parse('sylulive://competition/42');
      expect(result, isA<CompetitionScanPayload>());
      expect((result! as CompetitionScanPayload).eventId, 42);
    });

    test('解析课表分享码协议', () {
      final result =
          ScanResultParser.parse('sylulive://schedule/share/Ab_123-x');
      expect(result, isA<ScheduleShareScanPayload>());
      expect((result! as ScheduleShareScanPayload).code, 'Ab_123-x');
    });

    test('拒绝错误协议、额外路径和非法编号', () {
      expect(ScanResultParser.parse('https://sylulive.com/competition/42'),
          isNull);
      expect(ScanResultParser.parse('sylulive://competition/42/extra'), isNull);
      expect(ScanResultParser.parse('sylulive://competition/0'), isNull);
      expect(ScanResultParser.parse('sylulive://competition/abc'), isNull);
      expect(ScanResultParser.parse('sylulive://schedule/share/a'), isNull);
      expect(
          ScanResultParser.parse('sylulive://schedule/share/abc?x=1'), isNull);
    });
  });
}
