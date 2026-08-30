import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/forbidden_recovery_router.dart';

void main() {
  test('识别所有需要统一处理的 403 code', () {
    expect(
      ForbiddenRecoveryRouter.resolve('community_rules_required')?.kind,
      ForbiddenRecoveryKind.communityRulesRequired,
    );
    expect(
      ForbiddenRecoveryRouter.resolve('legal_consent_required')
          ?.consentIsRequired,
      isTrue,
    );
    expect(
      ForbiddenRecoveryRouter.resolve('legal_consent_withdrawn')
          ?.consentIsRequired,
      isFalse,
    );
    expect(
      ForbiddenRecoveryRouter.resolve('super_admin_required')
          ?.requiresAdminUiShutdown,
      isTrue,
    );
    expect(ForbiddenRecoveryRouter.resolve('other_forbidden'), isNull);
  });

  test('403 恢复只允许安全读取自动重试，写请求必须有幂等键', () {
    expect(
      ForbiddenRecoveryRouter.canReplay(
          method: 'GET', hasIdempotencyKey: false),
      isTrue,
    );
    expect(
      ForbiddenRecoveryRouter.canReplay(
          method: 'HEAD', hasIdempotencyKey: false),
      isTrue,
    );
    for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
      expect(
        ForbiddenRecoveryRouter.canReplay(
          method: method,
          hasIdempotencyKey: false,
        ),
        isFalse,
      );
      expect(
        ForbiddenRecoveryRouter.canReplay(
          method: method,
          hasIdempotencyKey: true,
        ),
        isTrue,
      );
    }
  });
}
