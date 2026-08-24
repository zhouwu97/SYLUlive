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
}
