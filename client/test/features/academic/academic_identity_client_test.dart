import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';

/// 只记录路由和脱敏请求字段，模拟已由 AuthProvider 注入 JWT 的 Dio。
final class _IdentityHttpAdapter implements HttpClientAdapter {
  final List<({int status, Object? body})> responses = [];
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests.add(options);
    if (responses.isEmpty) throw StateError('缺少身份接口测试响应');
    final response = responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  AcademicIdentityClient createClient(_IdentityHttpAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
      ..httpClientAdapter = adapter;
    return AcademicIdentityClient(dio);
  }

  Map<String, dynamic> challengeResponse({
    String providerId = 'sylu_graduate',
    String studentId = 'G-001',
    String? challengeType = 'school_login',
  }) {
    return <String, dynamic>{
      'challenge_required': true,
      'challenge_type': challengeType,
      'provider_id': providerId,
      'student_id': studentId,
      'challenge_token': 'opaque-challenge',
      'captcha': base64Encode(const <int>[1, 2, 3, 4]),
      'school_public_key':
          '-----BEGIN PUBLIC KEY-----\nfixture\n-----END PUBLIC KEY-----',
      'school_public_key_fingerprint': 'sha256:fixture',
      'expires_at': '2099-01-01T00:00:00Z',
    };
  }

  Map<String, dynamic> undergraduatePreverifyResponse() {
    return <String, dynamic>{
      'challenge_required': false,
      'provider_id': 'sylu_undergraduate',
      'student_id': 'U-001',
      'verification_mode': 'undergraduate_preverify',
      'verify_endpoint': '/api/student-identity/verify',
      'legacy_endpoint': '/api/edu/bind',
    };
  }

  test('GET 身份保留学校核验和历史继承项，challenge 正确解析验证码', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((
        status: 200,
        body: <String, dynamic>{
          'identities': <Map<String, dynamic>>[
            <String, dynamic>{
              'provider_id': 'sylu_graduate',
              'student_id': 'G-001',
              'verified': true,
              'verification_method': 'school_profile',
            },
            <String, dynamic>{
              'provider_id': 'sylu_undergraduate',
              'student_id': 'U-001',
              'verified': false,
              'verification_method': 'local_academic_login',
            },
            <String, dynamic>{
              'provider_id': 'sylu_undergraduate',
              'student_id': 'U-002',
              // 旧服务端可能仍把历史回填项报告为 verified=true。
              'verified': true,
              'verification_method': 'legacy_migration',
              'assurance_level': 'school_verified',
            },
          ],
        },
      ))
      ..responses.add((status: 200, body: challengeResponse()));
    final client = createClient(adapter);

    final identities = await client.listIdentities();
    final challenge = await client.requestChallenge(
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-001',
    );

    expect(identities, hasLength(2));
    expect(identities.first.providerId, AcademicProviderId.syluGraduate);
    expect(identities.first.isSchoolVerified, isTrue);
    expect(identities.last.studentId, 'U-002');
    expect(identities.last.verified, isTrue);
    expect(identities.last.isSchoolVerified, isFalse);
    expect(identities.last.assuranceLevel, academicAssuranceLegacyInherited);
    expect(
      academicIdentityStandingLabel(identities.last),
      '继承历史服务器认证状态',
    );
    expect(challenge, isNotNull);
    expect(challenge!.challengeType, 'school_login');
    expect(challenge.captchaBytes, orderedEquals(<int>[1, 2, 3, 4]));
    expect(adapter.requests[0].path, '/student-identity');
    expect(adapter.requests[1].path, '/student-identity/challenge');
    expect(
      Map<String, dynamic>.from(adapter.requests[1].data as Map),
      containsPair('provider_id', 'sylu_graduate'),
    );
    expect(
      Map<String, dynamic>.from(adapter.requests[1].data as Map),
      containsPair('student_id', 'G-001'),
    );
  });

  test('challenge 响应身份不匹配时拒绝，不能由客户端声明身份', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((
        status: 200,
        body: challengeResponse(studentId: 'G-002'),
      ));
    final client = createClient(adapter);

    await expectLater(
      client.requestChallenge(
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-001',
      ),
      throwsA(
        isA<AcademicIdentityApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('verify 请求携带加密密码，挑战重放保持独立错误码', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((status: 200, body: challengeResponse()))
      ..responses.add((
        status: 401,
        body: <String, dynamic>{'code': 'ACADEMIC_CHALLENGE_REPLAYED'},
      ));
    final client = createClient(adapter);
    final challenge = await client.requestChallenge(
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-001',
    );

    await expectLater(
      client.verify(
        challenge: challenge!,
        captcha: 'ABCD',
        encryptedPassword: 'encrypted-fixture',
      ),
      throwsA(
        isA<AcademicIdentityApiException>().having(
          (error) => error.code,
          'code',
          'ACADEMIC_CHALLENGE_REPLAYED',
        ),
      ),
    );
    final body = Map<String, dynamic>.from(adapter.requests.last.data as Map);
    expect(body['provider_id'], 'sylu_graduate');
    expect(body['student_id'], 'G-001');
    expect(body['challenge_token'], 'opaque-challenge');
    expect(body['encrypted_password'], 'encrypted-fixture');
    expect(body.containsKey('password'), isFalse);
  });

  test('本科 preverify 按实际契约提交 password，且只接受服务端 verified', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((
        status: 200,
        body: undergraduatePreverifyResponse(),
      ))
      ..responses.add((
        status: 200,
        body: <String, dynamic>{
          'verified': true,
          'provider_id': 'sylu_undergraduate',
          'student_id': 'U-001',
          'verification_method': 'school_profile',
          'verification_version': 'undergraduate-preverify-v1',
        },
      ));
    final client = createClient(adapter);
    final challenge = await client.requestChallenge(
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );

    final binding = await client.verifyUndergraduatePreverify(
      challenge: challenge!,
      password: 'password-fixture',
    );

    expect(challenge.isUndergraduatePreverify, isTrue);
    expect(binding.providerId, AcademicProviderId.syluUndergraduate);
    expect(binding.studentId, 'U-001');
    expect(adapter.requests[1].path, '/student-identity/verify');
    final body = Map<String, dynamic>.from(adapter.requests[1].data as Map);
    expect(body, containsPair('provider_id', 'sylu_undergraduate'));
    expect(body, containsPair('student_id', 'U-001'));
    expect(body, containsPair('password', 'password-fixture'));
    expect(
        body.keys,
        unorderedEquals(<String>[
          'provider_id',
          'student_id',
          'password',
        ]));
  });

  test('本科 preverify 未核验时保持 ACADEMIC_IDENTITY_UNVERIFIED，不映射密码错误', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((status: 200, body: undergraduatePreverifyResponse()))
      ..responses.add((
        status: 422,
        body: <String, dynamic>{'code': 'ACADEMIC_IDENTITY_UNVERIFIED'},
      ));
    final client = createClient(adapter);
    final challenge = await client.requestChallenge(
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );

    await expectLater(
      client.verifyUndergraduatePreverify(
        challenge: challenge!,
        password: 'password-fixture',
      ),
      throwsA(
        isA<AcademicIdentityApiException>()
            .having(
                (error) => error.code, 'code', 'ACADEMIC_IDENTITY_UNVERIFIED')
            .having((error) => error.message, 'message', contains('身份')),
      ),
    );
  });

  test('旧部署只有明确 404 才保留兼容回退信号', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((status: 404, body: <String, dynamic>{}));
    final client = createClient(adapter);

    await expectLater(
      client.requestChallenge(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
      ),
      throwsA(
        isA<AcademicIdentityApiException>()
            .having((error) => error.statusCode, 'statusCode', 404),
      ),
    );
  });

  test('研究生挑战纯文本 404 明确提示服务未开放而非密码错误', () async {
    final adapter = _IdentityHttpAdapter()
      ..responses.add((status: 404, body: '404 page not found'));
    final client = createClient(adapter);
    await expectLater(
      client.requestChallenge(
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-FIXTURE-001',
      ),
      throwsA(isA<AcademicIdentityApiException>()
          .having((e) => e.code, 'code', 'ACADEMIC_IDENTITY_ROUTE_UNAVAILABLE')
          .having((e) => e.message, 'message', contains('无需修改教务密码'))
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
    expect(adapter.requests, hasLength(1));
  });
  for (final graduate in [false, true]) {
    test('换绑挑战和提交使用独立端点：$graduate', () async {
      final data = graduate ? challengeResponse() : undergraduatePreverifyResponse();
      data.addAll({'operation': 'change', 'challenge_token': 'sealed-change', 'expires_at': '2099-01-01T00:00:00Z'});
      final provider = graduate ? AcademicProviderId.syluGraduate : AcademicProviderId.syluUndergraduate;
      final student = graduate ? 'G-001' : 'U-001';
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 200, body: data))
        ..responses.add((status: 200, body: {
          'verified': true,
          'provider_id': provider.value,
          'student_id': student,
          'verification_method': 'school_profile',
          'binding_version': 4,
          'changed_at': '2026-09-08T00:00:00Z',
        }));
      final client = createClient(adapter);
      final challenge = await client.requestChallenge(providerId: provider, studentId: student,
        currentIdentity: const AcademicIdentityKey(appUserId: 'u', providerId: AcademicProviderId.syluUndergraduate, studentId: 'OLD'));
      final binding = graduate
          ? await client.verify(challenge: challenge!, captcha: '1234', encryptedPassword: 'ciphertext')
          : await client.verifyUndergraduatePreverify(challenge: challenge!, password: 'fixture');
      expect(adapter.requests.first.path, '/student-identity/change/challenge');
      expect(adapter.requests.last.path, '/student-identity/change');
      expect(adapter.requests.last.data['challenge_token'], 'sealed-change');
      expect(binding.bindingVersion, 4);
      expect(binding.changedAt, isNotNull);
    });
  }

  group('本机声明回执契约', () {
    const identity = AcademicIdentityKey(
      appUserId: 'u-1',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'U-001',
    );

    Map<String, dynamic> localDeclaration(
            {String provider = 'sylu_undergraduate',
            String student = 'U-001',
            Object? verified = false,
            Object? method = 'local_academic_login',
            Object? assurance = 'local_declaration'}) =>
        <String, dynamic>{
          'provider_id': provider,
          'student_id': student,
          'verified': verified,
          'verification_method': method,
          'assurance_level': assurance,
          'binding_version': 1,
        };

    test('verified=false 的正常回执被当作「声明已接收」，不再是身份不一致', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 200, body: localDeclaration()));
      final binding = await createClient(adapter).bindLocal(identity);
      expect(binding.providerId, AcademicProviderId.syluUndergraduate);
      expect(binding.studentId, 'U-001');
      // 本机声明永远不构成可信学生认证。
      expect(binding.isSchoolVerified, isFalse);
      expect(binding.verified, isFalse);
      expect(binding.assuranceLevel, academicAssuranceLocalDeclaration);
    });

    test('旧服务端自称 verified=true 也不会被当成学校核验', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 200, body: localDeclaration(verified: true)));
      final binding = await createClient(adapter).bindLocal(identity);
      expect(binding.isSchoolVerified, isFalse);
    });

    test('回执身份不一致属于契约错误，不重试', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 200, body: localDeclaration(student: 'OTHER')));
      await expectLater(
        createClient(adapter).bindLocal(identity),
        throwsA(isA<AcademicIdentityApiException>()
            .having((e) => e.code, 'code', 'IDENTITY_MISMATCH')
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('回执核验方式不是本机声明属于契约错误，不重试', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add(
            (status: 200, body: localDeclaration(method: 'school_profile')));
      await expectLater(
        createClient(adapter).bindLocal(identity),
        throwsA(isA<AcademicIdentityApiException>()
            .having((e) => e.code, 'code', 'ACADEMIC_BINDING_CONTRACT_ERROR')
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('回执自称学校核验属于契约错误，不重试', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 200, body: localDeclaration(assurance: 'school_verified')));
      await expectLater(
        createClient(adapter).bindLocal(identity),
        throwsA(isA<AcademicIdentityApiException>()
            .having((e) => e.code, 'code', 'ACADEMIC_BINDING_CONTRACT_ERROR')
            .having((e) => e.isRetryable, 'isRetryable', isFalse)),
      );
    });

    test('网络故障属于临时问题，允许重试', () async {
      final adapter = _IdentityHttpAdapter()
        ..responses.add((status: 503, body: <String, dynamic>{'code': 'UNAVAILABLE'}));
      await expectLater(
        createClient(adapter).bindLocal(identity),
        throwsA(isA<AcademicIdentityApiException>()
            .having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });

    test('依据等级区分学校核验、历史回填和本机声明', () {
      expect(assuranceLevelFor('school_profile'), academicAssuranceSchoolVerified);
      expect(assuranceLevelFor('legacy_migration'), academicAssuranceLegacyInherited);
      expect(assuranceLevelFor('local_academic_login'), academicAssuranceLocalDeclaration);
      expect(assuranceLevelFor(null), academicAssuranceLocalDeclaration);
      expect(assuranceLevelFor(''), academicAssuranceLocalDeclaration);
      // 与服务端一致：精确匹配，未登记与带空白都不算可信。
      expect(assuranceLevelFor('test'), academicAssuranceLocalDeclaration);
      expect(assuranceLevelFor(' school_profile'), academicAssuranceLocalDeclaration);
      expect(assuranceLevelFor('school_profile_v2'), academicAssuranceLocalDeclaration);
    });

    test('旧版迁移身份不能凭服务端旧 verified 回执获得本次核验状态', () {
      final legacy = AcademicIdentityBinding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-002',
        verified: true,
        verificationMethod: academicVerificationMethodLegacyMigration,
        assuranceLevel: academicAssuranceSchoolVerified,
      );
      expect(legacy.isSchoolVerified, isFalse);
      expect(
        academicIdentityStandingLabel(legacy),
        '继承历史服务器认证状态',
      );
    });

    test('服务端撤销历史回填资格后显示待重新认证', () {
      final legacy = AcademicIdentityBinding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-002',
        verified: false,
        verificationMethod: academicVerificationMethodLegacyMigration,
        assuranceLevel: academicAssuranceLegacyInherited,
      );
      expect(legacy.isSchoolVerified, isFalse);
      expect(academicIdentityStandingLabel(legacy), '历史身份待重新认证');
    });
  });
  group('身份状态的分开表达', () {
    AcademicIdentityBinding binding({
      required AcademicProviderId providerId,
      required String studentId,
      bool verified = false,
      String? method,
    }) =>
        AcademicIdentityBinding(
          providerId: providerId,
          studentId: studentId,
          verified: verified,
          verificationMethod: method,
        );

    test('「本机已连接」不等于「身份已核验」', () {
      final localOnly = binding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
        verified: true,
        method: academicVerificationMethodLocalDeclaration,
      );
      expect(localOnly.isSchoolVerified, isFalse);
      expect(academicIdentityStandingLabel(localOnly), '仅本机连接，未完成学生认证');

      final schoolVerified = binding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
        verified: true,
        method: academicVerificationMethodSchoolProfile,
      );
      expect(schoolVerified.isSchoolVerified, isTrue);
      expect(academicIdentityStandingLabel(schoolVerified), '已完成学生认证');
    });

    test('本机账号与服务端可信绑定合并，不能一律显示成未认证', () {
      final local = binding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
      );
      final trusted = binding(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'U-001',
        verified: true,
        method: academicVerificationMethodSchoolProfile,
      );

      final merged = mergeAcademicIdentityStanding(
        localAccounts: [local],
        serverBindings: [trusted],
      );
      expect(merged, hasLength(1));
      expect(merged.single.isSchoolVerified, isTrue,
          reason: '已有学校核验的用户不能被显示成"没有认证"');

      final unverified = mergeAcademicIdentityStanding(
        localAccounts: [local],
        serverBindings: const [],
      );
      expect(unverified.single.isSchoolVerified, isFalse);
    });

    test('只有服务端绑定的设备直接显示其核验状态', () {
      final trusted = binding(
        providerId: AcademicProviderId.syluGraduate,
        studentId: 'G-001',
        verified: true,
        method: academicVerificationMethodSchoolProfile,
      );
      expect(
        mergeAcademicIdentityStanding(
          localAccounts: const [],
          serverBindings: [trusted],
        ),
        [trusted],
      );
    });
  });
}
