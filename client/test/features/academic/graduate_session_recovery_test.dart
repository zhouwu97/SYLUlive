import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/graduate/graduate_protocol_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_session_artifact_vault.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'academic_identity_lifecycle_test.dart' show Secrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  const identity = AcademicIdentityKey(
      appUserId: 'u',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-FIXTURE-001');
  for (final scenario in [
    'success',
    '500',
    'invalid-aes',
    'offline',
    'identity-mismatch',
    'unknown-redirect',
    'expired'
  ]) {
    test('研究生真实协议客户端恢复分类：$scenario', () async {
      final secrets = Secrets();
      final credentials = PlatformAcademicCredentialStore(secretStore: secrets);
      await credentials.writeForIdentity(
          identity,
          const AcademicCredential(
              studentId: 'G-FIXTURE-001', password: 'fixture'));
      final vault = AcademicSessionArtifactVault(
          identity: identity,
          secretStore: secrets,
          fileBackend: MemoryAcademicSessionArtifactFileBackend());
      final created = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      await vault.write(ProviderSessionArtifact(
          providerId: identity.providerId,
          studentId: identity.studentId,
          artifactVersion: graduateProtocolVersion,
          createdAt: created,
          validatedAt: created,
          opaqueProviderState: const {
            'cookies': ['ASP.NET_SessionId=fixture; Path=/; Secure'],
            'session_path_prefix': '',
          }));
      final dio = Dio(BaseOptions(baseUrl: graduatePortalBaseUrl,
          followRedirects: false, validateStatus: (_) => true));
      final gateway = GraduateProtocolClient(dio: dio);
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (scenario == 'offline') {
          handler.reject(DioException(requestOptions: options,
              type: DioExceptionType.connectionError));
          return;
        }
        final redirect =
            scenario == 'expired' || scenario == 'unknown-redirect';
        handler.resolve(Response<String>(
          requestOptions: options,
          statusCode: redirect
              ? 302
              : scenario == '500'
                  ? 500
                  : 200,
          headers: Headers.fromMap({
            if (redirect)
              'location': [
                scenario == 'expired' ? '/home/stulogin' : '/maintenance',
              ]
          }),
          data: scenario == 'success' || scenario == 'identity-mismatch'
              ? jsonEncode([
                  {'xh': scenario == 'success' ? identity.studentId : 'OTHER', 'xm': '测试学生'}
                ])
              : 'invalid ciphertext',
        ));
      }));
      final provider =
          GraduateAcademicProvider(identity: identity, gateway: gateway);
      final controller = AcademicSessionController.forProvider(
          provider: provider,
          identity: identity,
          sessionArtifactVaultFactory: (_) => vault);
      await AcademicConnectionStore(identity, await AppPreferencesStore.getInstance()).setConnected(true);
      await controller.syncAppUser(identity.appUserId);
      expect(await controller.ensureAuthenticated(), scenario == 'success');
      final artifact = await vault.read();
      if (scenario == 'expired') {
        expect(artifact, isNull);
      } else {
        expect(artifact, isNotNull);
        expect(artifact!.createdAt, created);
        expect(artifact.validatedAt!.isAfter(created), scenario == 'success');
      }
      expect(await credentials.readForIdentity(identity), isNotNull);
      expect(await gateway.exportSession(),
          scenario == 'success' ? isNotNull : isNull);
      controller.dispose();
      provider.close();
    });
  }
}
