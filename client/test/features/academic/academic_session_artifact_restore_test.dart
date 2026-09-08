import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_session_artifact_vault.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'academic_identity_lifecycle_test.dart' show Secrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  const identity = AcademicIdentityKey(
      appUserId: 'u',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001');
  for (final scenario in ['authenticated', 'expired', '500', 'unknown']) {
    test('本科 Cookie 冷恢复分类：$scenario', () async {
      final secrets = Secrets();
      final vault = AcademicSessionArtifactVault(
          identity: identity,
          secretStore: secrets,
          fileBackend: MemoryAcademicSessionArtifactFileBackend());
      final created = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      await vault.write(ProviderSessionArtifact(
          providerId: identity.providerId,
          studentId: identity.studentId,
          artifactVersion: 1,
          createdAt: created,
          validatedAt: created,
          opaqueProviderState: const {
            'cookies': ['JSESSIONID=fixture; Path=/; Secure; HttpOnly']
          }));
      var receivedCookie = false;
      final dio = Dio();
      final client = JiaowuClient(dio: dio);
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        receivedCookie =
            options.headers['cookie'].toString().contains('JSESSIONID=fixture');
        final body = scenario == 'authenticated'
            ? File('../experiments/jiaowu_dart_poc/test/fixtures/profile/profile_normal.html')
                .readAsStringSync()
            : '<html>unknown</html>';
        handler.resolve(Response(
            requestOptions: options,
            data: body,
            statusCode: scenario == 'expired'
                ? 901
                : scenario == '500'
                    ? 500
                    : 200));
      }));
      final provider = UndergraduateAcademicProvider(
          identity: identity,
          source: JiaowuLocalDataSource(clientFactory: () => client));
      final controller = AcademicSessionController.forProvider(
          provider: provider,
          identity: identity,
          sessionArtifactVaultFactory: (_) => vault);
      await controller.syncAppUser('u');
      final result = await AcademicLoginCoordinator(controller: controller)
          .ensureAuthenticated(allowSavedCredential: false);
      final artifact = await vault.read();
      expect(result.isSuccess, scenario == 'authenticated');
      if (scenario == '500' || scenario == 'unknown') {
        expect(result.kind, isNot(AcademicLoginOutcomeKind.credentialsRequired));
      }
      if (scenario == 'expired') {
        expect(artifact, isNull);
        expect(secrets.values, isEmpty);
      } else {
        expect(artifact, isNotNull);
        expect(artifact!.createdAt, created);
        expect(artifact.validatedAt!.isAfter(created),
            scenario == 'authenticated');
      }
      if (scenario == 'authenticated') expect(receivedCookie, true);
      controller.dispose();
      provider.close();
    });
  }
}
