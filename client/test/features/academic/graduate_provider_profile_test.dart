import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/graduate/graduate_protocol_client.dart';
import 'package:shenliyuan/features/academic/data/provider_academic_repository.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';

void main() {
  test('研究生资料脱敏 fixture 按数组响应解析 xh/xm', () {
    final decoded = GraduateResponseCodec.decode(
      jsonEncode([
        {
          'xh': 'G-FIXTURE-001',
          'xm': '测试同学',
          'xsmc': '测试学院',
          'zymc': '测试专业',
        },
      ]),
    );

    final profile = GraduateProfile.fromDecoded(decoded);

    expect(profile.studentId, 'G-FIXTURE-001');
    expect(profile.name, '测试同学');
  });

  test('研究生 Provider 只接受学校返回的匹配身份', () async {
    const identity = AcademicIdentityKey(
      appUserId: 'app-fixture',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-FIXTURE-001',
    );
    final provider = GraduateAcademicProvider(
      identity: identity,
      gateway: _FakeGraduateGateway(
        const GraduateProfile(studentId: 'G-FIXTURE-999', name: '其他同学'),
      ),
    );

    await expectLater(
      provider.fetchProfile(),
      throwsA(
        isA<AcademicAuthFailure>().having(
          (error) => error.type,
          'type',
          AcademicAuthFailureType.identityMismatch,
        ),
      ),
    );
    provider.close();
  });

  test('研究生登录传输超时映射为超时网络异常', () async {
    final provider = GraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-fixture',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      gateway: _FakeGraduateGateway(
        const GraduateProfile(),
        loginError: DioException(
          requestOptions: RequestOptions(path: '/login'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
    );

    await expectLater(
      provider.login(
        const AcademicLoginRequest(
          studentId: 'G-FIXTURE-001',
          password: 'secret',
          captchaCode: '1234',
        ),
      ),
      throwsA(
        isA<RequestTimeoutException>().having(
          (error) => error.code,
          'code',
          'REQUEST_TIMEOUT',
        ),
      ),
    );
    provider.close();
  });

  test('研究生登录连接失败保留连接类网络错误', () async {
    final provider = GraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-fixture',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      gateway: _FakeGraduateGateway(
        const GraduateProfile(),
        loginError: DioException(
          requestOptions: RequestOptions(path: '/login'),
          type: DioExceptionType.connectionError,
        ),
      ),
    );

    await expectLater(
      provider.login(
        const AcademicLoginRequest(
          studentId: 'G-FIXTURE-001',
          password: 'secret',
          captchaCode: '1234',
        ),
      ),
      throwsA(
        isA<NetworkException>().having(
          (error) => error.code,
          'code',
          'CONNECTION_FAILED',
        ),
      ),
    );
    provider.close();
  });

  test('研究生登录 HTTP 500/503 归为上游暂不可用并保留状态码', () async {
    for (final status in [500, 503]) {
      final requestOptions = RequestOptions(
        baseUrl: graduatePortalBaseUrl,
        path: '/home/stulogin_do',
      );
      final provider = GraduateAcademicProvider(
        identity: const AcademicIdentityKey(
          appUserId: 'app-fixture',
          providerId: AcademicProviderId.syluGraduate,
          studentId: 'G-FIXTURE-001',
        ),
        gateway: _FakeGraduateGateway(
          const GraduateProfile(),
          loginError: DioException(
            requestOptions: requestOptions,
            type: DioExceptionType.badResponse,
            response: Response<String>(
              requestOptions: requestOptions,
              statusCode: status,
              data: 'must-not-leak',
            ),
          ),
        ),
      );

      await expectLater(
        provider.login(
          const AcademicLoginRequest(
            studentId: 'G-FIXTURE-001',
            password: 'secret',
            captchaCode: '1234',
          ),
        ),
        throwsA(
          isA<NetworkException>()
              .having((error) => error.code, 'code', 'UPSTREAM_HTTP_$status')
              .having(
                (error) => error.diagnostic?.statusCode,
                'statusCode',
                status,
              ),
        ),
      );
      provider.close();
    }
  });

  test('研究生登录 Codec 格式异常映射为明确协议错误', () async {
    final provider = GraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-fixture',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      gateway: _FakeGraduateGateway(
        const GraduateProfile(),
        loginError: const FormatException('fixture response'),
      ),
    );

    await expectLater(
      provider.login(
        const AcademicLoginRequest(
          studentId: 'G-FIXTURE-001',
          password: 'secret',
          captchaCode: '1234',
        ),
      ),
      throwsA(
        isA<ParseException>().having(
          (error) => error.code,
          'code',
          'GRADUATE_CODEC_FAILED',
        ),
      ),
    );
    provider.close();
  });

  test('研究生验证码提交失败后下一次登录会重新获取 challenge', () async {
    final gateway = _FakeGraduateGateway(
      const GraduateProfile(),
      loginError: const FormatException('fixture response'),
    );
    final provider = GraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-fixture',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      gateway: gateway,
    );

    await provider.prepareLogin();
    await expectLater(
      provider.login(
        const AcademicLoginRequest(
          studentId: 'G-FIXTURE-001',
          password: 'secret',
          captchaCode: '1234',
        ),
      ),
      throwsA(isA<ParseException>()),
    );

    final next = await provider.login(
      const AcademicLoginRequest(
        studentId: 'G-FIXTURE-001',
        password: 'secret',
      ),
    );

    expect(next, isA<AcademicLoginChallengeRequired>());
    expect(gateway.prepareCalls, 2);
    provider.close();
  });

  test('兼容仓储在验证码提交异常后也会丢弃旧 challenge', () async {
    final gateway = _FakeGraduateGateway(
      const GraduateProfile(),
      loginError: const FormatException('fixture response'),
    );
    final provider = GraduateAcademicProvider(
      identity: const AcademicIdentityKey(
        appUserId: 'app-fixture',
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      gateway: gateway,
    );
    final repository = ProviderAcademicRepository(provider);

    expect(
      await repository.login(
        studentId: 'G-FIXTURE-001',
        password: 'secret',
      ),
      isA<CaptchaRequired>(),
    );
    await expectLater(
      repository.continueLoginWithCaptcha(code: '1234'),
      throwsA(isA<ParseException>()),
    );
    await repository.getCaptchaChallenge();

    expect(gateway.prepareCalls, 2);
    repository.close();
  });
}

final class _FakeGraduateGateway implements GraduateProtocolGateway {
  _FakeGraduateGateway(this.profile, {this.loginError});

  final GraduateProfile profile;
  final Object? loginError;
  int prepareCalls = 0;

  @override
  Future<GraduateCaptcha> prepareLogin() async {
    prepareCalls++;
    return GraduateCaptcha(Uint8List.fromList(const [0]));
  }

  @override
  Future<GraduateCaptcha> refreshCaptcha() async =>
      GraduateCaptcha(Uint8List.fromList(const [0]));

  @override
  Future<void> login({
    required String studentId,
    required String password,
    required String captchaCode,
  }) async {
    final error = loginError;
    if (error != null) throw error;
  }

  @override
  Future<List<GraduateTerm>> fetchTerms() async => const [];

  @override
  Future<GraduateSchedule> fetchSchedule(String termCode) async =>
      const GraduateSchedule(slots: []);

  @override
  Future<GraduateProfile> fetchProfile() async => profile;

  @override
  Future<GraduateSessionState> probe() async => GraduateSessionState(
      authenticated: profile.studentId != null, studentId: profile.studentId);

  @override
  Future<GraduateSessionArtifactState?> exportSession() async => null;

  @override
  Future<void> restoreSession(GraduateSessionArtifactState artifact) async {}

  @override
  Future<void> reset() async {}

  @override
  void close() {}
}
