import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/screens/publish/market_publish_eligibility.dart';

void main() {
  group('集市发布被拒文案', () {
    test('不能把「未核验」说成「毕业」', () {
      for (final hasLocal in [true, false]) {
        final message =
            marketPublishBlockedMessage(hasLocalAcademicConnection: hasLocal);
        expect(message, isNot(contains('毕业')),
            reason: '缺少学生认证与学历无关，文案不能误导用户去处理毕业状态');
        expect(message, contains('学生认证'));
      }
    });

    test('说清楚缺的是哪一种可信凭据', () {
      final message =
          marketPublishBlockedMessage(hasLocalAcademicConnection: false);
      expect(marketPublishRequiredCredential, '服务器学生认证');
      expect(message, contains(marketPublishRequiredCredential));
    });

    test('本机已连接与尚未连接给出不同的下一步', () {
      final local =
          marketPublishBlockedMessage(hasLocalAcademicConnection: true);
      final none =
          marketPublishBlockedMessage(hasLocalAcademicConnection: false);
      expect(local, isNot(equals(none)));
      // 已连接的用户需要知道「连接不等于认证」，否则会以为再连一次就能发。
      expect(local, contains('本机连接不构成学生认证'));
      expect(none, isNot(contains('本机已连接教务')));
    });

    test('给出可执行入口，并且不诱导反复重绑', () {
      for (final hasLocal in [true, false]) {
        final message =
            marketPublishBlockedMessage(hasLocalAcademicConnection: hasLocal);
        expect(message, contains('账号安全 - 教务身份与本机连接'));
        expect(message, contains('无需反复重新绑定'));
      }
    });

    test('服务端已给出说明时透传，不再叠一层猜测', () {
      expect(
        marketPublishServerDeniedMessage('当前账号受限，暂时不能发布集市帖子'),
        '当前账号受限，暂时不能发布集市帖子',
      );
      // 服务端没给说明时退回本地文案，不能显示空白。
      expect(
        marketPublishServerDeniedMessage(null),
        contains('学生认证'),
      );
      expect(
        marketPublishServerDeniedMessage('   '),
        contains('学生认证'),
      );
    });
  });
}
