import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';

void main() {
  group('academicSessionReadBarrierFor —— 需要人工 vs 临时故障', () {
    test('临时故障在退避结束后要能再次无感恢复', () {
      for (final kind in [
        AcademicLoginOutcomeKind.networkFailure,
        AcademicLoginOutcomeKind.challengeRejected,
        AcademicLoginOutcomeKind.authRejectedAmbiguous,
      ]) {
        expect(academicSessionReadBarrierFor(kind),
            AcademicSessionReadBarrier.transient,
            reason: '$kind 会自己变好，永久阻塞会让退避到期也不会恢复');
      }
    });

    test('需要人工输入或人工处理的状态不能反复弹框', () {
      for (final kind in [
        AcademicLoginOutcomeKind.captchaRequired,
        AcademicLoginOutcomeKind.credentialsRequired,
        AcademicLoginOutcomeKind.invalidCredentials,
        AcademicLoginOutcomeKind.accountRejected,
        AcademicLoginOutcomeKind.accountRestricted,
        AcademicLoginOutcomeKind.identityMismatch,
        AcademicLoginOutcomeKind.identityUnverified,
        AcademicLoginOutcomeKind.profileFailure,
      ]) {
        expect(academicSessionReadBarrierFor(kind),
            AcademicSessionReadBarrier.needsManual,
            reason: '$kind 重试不会变好，只能由用户处理');
      }
    });

    test('成功与上下文切换都不记阻塞', () {
      expect(academicSessionReadBarrierFor(AcademicLoginOutcomeKind.success),
          AcademicSessionReadBarrier.none);
      expect(academicSessionReadBarrierFor(AcademicLoginOutcomeKind.contextChanged),
          AcademicSessionReadBarrier.none);
    });

    test('笼统的 failure 按教务失败的既有可重试分类拆开', () {
      expect(
        academicSessionReadBarrierFor(AcademicLoginOutcomeKind.failure,
            failureRetryable: true),
        AcademicSessionReadBarrier.transient,
      );
      expect(
        academicSessionReadBarrierFor(AcademicLoginOutcomeKind.failure,
            failureRetryable: false),
        AcademicSessionReadBarrier.needsManual,
      );
    });
  });
}
