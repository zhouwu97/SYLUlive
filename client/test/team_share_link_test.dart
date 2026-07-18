import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/team_share_link.dart';

void main() {
  group('TeamShareLink', () {
    test('生成固定域名的 HTTPS 分享链接', () {
      expect(
        TeamShareLink.webUri(42).toString(),
        'https://sylulive.online/team/42',
      );
    });

    test('解析 HTTPS 与自定义协议链接', () {
      expect(
        TeamShareLink.parseRecruitmentId(
          'https://sylulive.online/team/42?from=share',
        ),
        42,
      );
      expect(TeamShareLink.parseRecruitmentId('sylulive://team/99'), 99);
    });

    test('拒绝非目标域名、额外路径和非法 ID', () {
      expect(
        TeamShareLink.parseRecruitmentId('https://example.com/team/42'),
        isNull,
      );
      expect(
        TeamShareLink.parseRecruitmentId(
          'https://sylulive.online/team/42/extra',
        ),
        isNull,
      );
      expect(
        TeamShareLink.parseRecruitmentId('https://sylulive.online/team/0'),
        isNull,
      );
      expect(TeamShareLink.parseRecruitmentId('sylulive://team/not-a-number'),
          isNull);
    });

    test('生成链接时拒绝非正整数 ID', () {
      expect(() => TeamShareLink.webUri(0), throwsArgumentError);
    });
  });
}
