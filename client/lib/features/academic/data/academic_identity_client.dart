import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../domain/academic_provider.dart';

/// 服务端身份绑定接口的脱敏错误。响应正文不向上层透传，避免把 JWT、
/// 学校临时状态或其他敏感字段带入日志和界面。
final class AcademicIdentityApiException implements Exception {
  const AcademicIdentityApiException(this.code, this.message,
      {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  /// 是否属于「再试一次会变好」的临时故障。
  ///
  /// 契约错误（回执格式不符、身份不一致、账号受限）重试多少次都不会变好，
  /// 只会让用户每隔几十秒收到一次同步失败。这类错误必须停下并给出可执行的下一步，
  /// 不能挂在定时器上无限重试。
  bool get isRetryable => switch (code) {
        'IDENTITY_MISMATCH' ||
        'ACADEMIC_BINDING_CONTRACT_ERROR' ||
        'INVALID_RESPONSE' ||
        'INVALID_REQUEST' ||
        'INVALID_LOCAL_BINDING' ||
        'INVALID_PROVIDER' ||
        'INVALID_STUDENT_ID' ||
        'ACCOUNT_RESTRICTED' ||
        'AUTHENTICATION_REQUIRED' ||
        'ACADEMIC_IDENTITY_ROUTE_UNAVAILABLE' =>
          false,
        _ => true,
      };

  @override
  String toString() => 'AcademicIdentityApiException($code)';
}

/// 本机登录成功声明的核验方式。
///
/// 它只证明「这台设备上的教务登录成功了」，不是服务器可独立核验的学生身份。
/// 必须与服务端 models.AcademicVerificationMethodLocalDeclaration 保持一致。
const academicVerificationMethodLocalDeclaration = 'local_academic_login';
const academicVerificationMethodSchoolProfile = 'school_profile';
const academicVerificationMethodLegacyMigration = 'legacy_migration';

/// 依据强度：学校核验、历史回填、本机声明。
const academicAssuranceSchoolVerified = 'school_verified';
const academicAssuranceLocalDeclaration = 'local_declaration';
const academicAssuranceLegacyInherited = 'legacy_inherited';

/// 身份状态文案：「本机已连接」不等于「身份已核验」。
///
/// 历史回填仍可能按兼容策略拥有准入，文案单独说明其来源，避免误称为本次学校核验。
String academicIdentityStandingLabel(AcademicIdentityBinding binding) {
  if (binding.isSchoolVerified) return '已完成学生认证';
  if (binding.verificationMethod == academicVerificationMethodLegacyMigration) {
    return binding.verified ? '继承历史服务器认证状态' : '历史身份待重新认证';
  }
  return '仅本机连接，未完成学生认证';
}

/// 合并「本机连过谁」与「服务端记录的身份状态」。
///
/// 这是两件不同的事：本机账号只说明这台设备上登录过哪些教务账号，
/// 服务端准入绑定决定受限功能能不能用，历史回填状态会单独标出。历史实现直接把本机账号渲染成
/// `verified: false`，于是已经有学校核验的用户也会被显示成"没有认证"。
///
/// [localAccounts] 为空时返回 [serverBindings]（例如只有服务端绑定的设备）。
List<AcademicIdentityBinding> mergeAcademicIdentityStanding({
  required List<AcademicIdentityBinding> localAccounts,
  required List<AcademicIdentityBinding> serverBindings,
}) {
  if (localAccounts.isEmpty) return serverBindings;
  return <AcademicIdentityBinding>[
    for (final account in localAccounts)
      serverBindings.firstWhere(
        (binding) =>
            binding.providerId == account.providerId &&
            binding.studentId == account.studentId,
        orElse: () => account,
      ),
  ];
}

/// 由核验方式推导依据强度。
///
/// 历史回填保留独立等级，不伪装成本次学校核验；白名单之外（含空值、未知取值、
/// 带空白的历史脏数据）一律按本机声明处理。服务端同样用精确匹配，不做 Trim。
String assuranceLevelFor(String? verificationMethod) {
  if (verificationMethod == academicVerificationMethodSchoolProfile) {
    return academicAssuranceSchoolVerified;
  }
  if (verificationMethod == academicVerificationMethodLegacyMigration) {
    return academicAssuranceLegacyInherited;
  }
  return academicAssuranceLocalDeclaration;
}

final class AcademicIdentityBinding {
  const AcademicIdentityBinding({
    required this.providerId,
    required this.studentId,
    required this.verified,
    this.verifiedAt,
    this.bindingVersion = 1,
    this.changedAt,
    this.verificationMethod,
    this.verificationVersion,
    this.assuranceLevel,
  });

  final AcademicProviderId providerId;
  final String studentId;
  final bool verified;
  final int bindingVersion;
  final DateTime? changedAt;
  final DateTime? verifiedAt;
  final String? verificationMethod;
  final String? verificationVersion;

  /// 服务端自报的依据强度；缺失时按 [verificationMethod] 推导。
  final String? assuranceLevel;

  /// 是否构成服务器可独立核验的学生身份。
  ///
  /// 「本机已连接」「配置已同步」「身份已核验」是三件不同的事。本机声明
  /// （local_academic_login）即使服务端回了 verified=true 也不算核验：
  /// 那只是「声明已接收」，不能据此开放受限功能。
  bool get isSchoolVerified =>
      verified &&
      verificationMethod == academicVerificationMethodSchoolProfile &&
      (assuranceLevel ?? assuranceLevelFor(verificationMethod)) ==
          academicAssuranceSchoolVerified;

  AcademicIdentityKey toIdentity(String appUserId) => AcademicIdentityKey(
        appUserId: appUserId,
        providerId: providerId,
        studentId: studentId,
      );
}

/// Provider 身份验证契约。
///
/// 研究生实例包含一次性 challenge 和学校公钥；本科实例只包含
/// `undergraduate_preverify` 模式及服务端 verify endpoint。密码只由调用方
/// 在一次请求期间短暂持有，challenge 材料不落地到持久化存储。
final class AcademicIdentityChallenge {
  const AcademicIdentityChallenge({
    required this.providerId,
    required this.studentId,
    required this.challengeType,
    this.verificationMode = 'school_login',
    this.challengeToken,
    this.captchaBytes,
    this.schoolPublicKey,
    this.schoolPublicKeyFingerprint,
    this.expiresAt,
    this.verifyEndpoint,
    this.legacyEndpoint,
    this.isChange = false,
  });

  final AcademicProviderId providerId;
  final String studentId;
  final String challengeType;
  final String verificationMode;
  final String? challengeToken;
  final Uint8List? captchaBytes;
  final String? schoolPublicKey;
  final String? schoolPublicKeyFingerprint;
  final DateTime? expiresAt;
  final String? verifyEndpoint;
  final String? legacyEndpoint;
  final bool isChange;

  bool get isUndergraduatePreverify =>
      verificationMode.trim().toLowerCase() == 'undergraduate_preverify';

  bool get isExpired =>
      expiresAt == null || !expiresAt!.isAfter(DateTime.now().toUtc());
}

/// 访问服务端 provider-aware 身份路由。Dio 必须是已由 AuthProvider 注入
/// JWT 的共享实例；本类不自己读取或保存 App Token。
final class AcademicIdentityClient {
  AcademicIdentityClient(this._dio);

  final Dio _dio;

  /// 本机完成登录探活后上报。App 用户由共享 Dio 的 JWT 确定，禁止附带学校凭据。
  ///
  /// 成功判据是「声明已接收」，不是「学校已核验」：这个接口不接触学校，
  /// 服务端正确实现会回 verified=false / assurance_level=local_declaration。
  /// 历史实现把它交给 [AcademicIdentityBinding] 的"学校已核验"解析器，
  /// 于是新后端的 200 正常响应被当成 IDENTITY_MISMATCH，同步永远失败并定时重试。
  Future<AcademicIdentityBinding> bindLocal(AcademicIdentityKey identity) async {
    try {
      final response = await _dio.post('/student-identity/bind', data: {
        'provider_id': identity.providerId.value,
        'student_id': identity.studentId,
        'verification_method': academicVerificationMethodLocalDeclaration,
      }, options: Options(headers: {'X-Expected-App-User': identity.appUserId},
          sendTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 12)));
      return _parseLocalDeclarationBinding(_requireMap(response, '同步学生身份'),
        expectedProvider: identity.providerId, expectedStudentId: identity.studentId);
    } on AcademicIdentityApiException {
      rethrow;
    } on DioException catch (error) {
      throw _networkError(error, '同步学生身份失败');
    }
  }

  Future<void> unbind(AcademicIdentityKey identity) async {
    try {
      final response = await _dio.delete('/student-identity', data: {
        'provider_id': identity.providerId.value, 'student_id': identity.studentId,
      });
      if (_requireMap(response, '解除教务绑定')['unbound'] != true) {
        throw const AcademicIdentityApiException('INVALID_RESPONSE', '服务器未确认解绑');
      }
    } on DioException catch (error) {
      throw _networkError(error, '解除教务绑定失败');
    }
  }

  Future<List<AcademicIdentityBinding>> listIdentities() async {
    final cancellation = CancelToken();
    try {
      final response = await _dio.get('/student-identity', cancelToken: cancellation)
          .timeout(const Duration(seconds: 12), onTimeout: () {
        cancellation.cancel('identity_restore_timeout');
        throw const AcademicIdentityApiException('IDENTITY_TIMEOUT',
            '确认教务身份超时，请检查网络后重试');
      });
      final data = _requireMap(response, '读取教务身份');
      final raw = data['identities'];
      if (raw is! List) {
        throw const AcademicIdentityApiException(
          'INVALID_RESPONSE',
          '教务身份响应格式无效',
        );
      }
      final bindings = <AcademicIdentityBinding>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final method = item['verification_method']?.toString();
        final isSchoolVerified = item['verified'] == true &&
            method == academicVerificationMethodSchoolProfile;
        final isLegacyInherited =
            method == academicVerificationMethodLegacyMigration;
        if (!isSchoolVerified && !isLegacyInherited) continue;
        final providerId = AcademicProviderId.tryParse(
          item['provider_id']?.toString() ?? '',
        );
        final studentId = item['student_id']?.toString().trim() ?? '';
        if (providerId == null || studentId.isEmpty) continue;
        bindings.add(
          AcademicIdentityBinding(
            providerId: providerId,
            studentId: studentId,
            verified: item['verified'] == true,
            verifiedAt: DateTime.tryParse(
              item['verified_at']?.toString() ?? '',
            )?.toUtc(),
            verificationMethod: method,
            verificationVersion: item['verification_version']?.toString(),
            bindingVersion: (item['binding_version'] as num?)?.toInt() ?? 1,
            changedAt: DateTime.tryParse(item['changed_at']?.toString() ?? ''),
            assuranceLevel: assuranceLevelFor(method),
          ),
        );
      }
      return List<AcademicIdentityBinding>.unmodifiable(bindings);
    } on AcademicIdentityApiException {
      rethrow;
    } on DioException catch (error) {
      throw _networkError(error, '读取教务身份失败');
    }
  }

  /// 200 响应必须声明本科 `undergraduate_preverify` 模式；旧部署仅在
  /// challenge 路由明确返回 404 或 ROUTE_UNSUPPORTED 时由协调器回退。
  Future<AcademicIdentityChallenge?> requestChallenge({
    required AcademicProviderId providerId,
    required String studentId,
    String? redirectUri,
    AcademicIdentityKey? currentIdentity,
  }) async {
    final normalizedStudentId = studentId.trim();
    if (normalizedStudentId.isEmpty) {
      throw const AcademicIdentityApiException(
        'INVALID_REQUEST',
        '请输入教务学号',
      );
    }
    try {
      final response = await _dio.post(
        currentIdentity == null ? '/student-identity/challenge' : '/student-identity/change/challenge',
        data: <String, Object?>{
          if (currentIdentity != null) ...{
            'current_provider_id': currentIdentity.providerId.value,
            'current_student_id': currentIdentity.studentId,
          },
          'provider_id': providerId.value,
          'student_id': normalizedStudentId,
          if (redirectUri != null && redirectUri.trim().isNotEmpty)
            'redirect_uri': redirectUri.trim(),
        },
      );
      final data = _requireMap(response, '获取教务挑战');
      if (currentIdentity != null &&
          (data['operation'] != 'change' ||
           (data['challenge_token']?.toString().isEmpty ?? true) ||
           DateTime.tryParse(data['expires_at']?.toString() ?? '') == null)) {
        throw const AcademicIdentityApiException('INVALID_RESPONSE', '服务端未返回有效换绑挑战');
      }
      final required = data['challenge_required'] == true;
      final challengeProvider = AcademicProviderId.tryParse(
        data['provider_id']?.toString() ?? '',
      );
      final challengeStudent = data['student_id']?.toString().trim() ?? '';
      final verificationMode =
          data['verification_mode']?.toString().trim().toLowerCase() ?? '';
      if (!required &&
          verificationMode == 'undergraduate_preverify' &&
          providerId == AcademicProviderId.syluUndergraduate &&
          challengeProvider == providerId &&
          challengeStudent == normalizedStudentId) {
        return AcademicIdentityChallenge(
          providerId: challengeProvider!,
          studentId: challengeStudent,
          challengeType: verificationMode,
          isChange: currentIdentity != null,
          challengeToken: data['challenge_token']?.toString(),
          schoolPublicKeyFingerprint: data['school_public_key_fingerprint']?.toString(),
          expiresAt: DateTime.tryParse(data['expires_at']?.toString() ?? ''),
          verificationMode: verificationMode,
          verifyEndpoint: _normalizeApiPath(
            data['verify_endpoint'],
            fallback: '/student-identity/verify',
          ),
          legacyEndpoint: data['legacy_endpoint']?.toString(),
        );
      }
      if (!required) {
        // 新服务端必须明确声明验证模式；只有路由不存在时调用方才允许
        // 回退旧 /edu/bind，避免把任意响应误当成已验证身份。
        throw const AcademicIdentityApiException(
          'INVALID_RESPONSE',
          '本科教务身份验证模式无效',
        );
      }
      final challengeToken = data['challenge_token']?.toString().trim() ?? '';
      final captcha = _decodeBase64(data['captcha']);
      final publicKey = data['school_public_key']?.toString().trim() ?? '';
      final fingerprint =
          data['school_public_key_fingerprint']?.toString().trim() ?? '';
      final rawChallengeType = data['challenge_type']?.toString().trim() ?? '';
      final expiresAt = DateTime.tryParse(
        data['expires_at']?.toString() ?? '',
      )?.toUtc();
      final resolvedProvider = challengeProvider;
      if (resolvedProvider == null ||
          resolvedProvider != providerId ||
          challengeStudent != normalizedStudentId ||
          challengeToken.isEmpty ||
          captcha == null ||
          captcha.isEmpty ||
          publicKey.isEmpty ||
          fingerprint.isEmpty ||
          expiresAt == null) {
        throw const AcademicIdentityApiException(
          'INVALID_RESPONSE',
          '教务挑战响应格式无效',
        );
      }
      return AcademicIdentityChallenge(
        providerId: resolvedProvider,
        isChange: currentIdentity != null,
        studentId: challengeStudent,
        // 研究生服务端当前以 school_login 表示“学校登录前置验证”，
        // 即使旧服务端漏传类型也按该协议处理。
        challengeType:
            rawChallengeType.isEmpty ? 'school_login' : rawChallengeType,
        verificationMode:
            verificationMode.isEmpty ? 'school_login' : verificationMode,
        challengeToken: challengeToken,
        captchaBytes: Uint8List.fromList(captcha),
        schoolPublicKey: publicKey,
        schoolPublicKeyFingerprint: fingerprint,
        expiresAt: expiresAt,
      );
    } on AcademicIdentityApiException {
      rethrow;
    } on DioException catch (error) {
      throw _networkError(error, '获取教务挑战失败');
    }
  }

  Future<AcademicIdentityBinding> verify({
    required AcademicIdentityChallenge challenge,
    required String captcha,
    required String encryptedPassword,
  }) async {
    if (challenge.isUndergraduatePreverify) {
      throw const AcademicIdentityApiException(
        'INVALID_REQUEST',
        '本科身份请使用 verify-only 请求',
      );
    }
    final challengeToken = challenge.challengeToken;
    final fingerprint = challenge.schoolPublicKeyFingerprint;
    if (challenge.isExpired || challengeToken == null || fingerprint == null) {
      throw const AcademicIdentityApiException(
        'CHALLENGE_EXPIRED',
        '教务挑战已过期，请重新获取',
      );
    }
    final normalizedCaptcha = captcha.trim();
    final normalizedEncryptedPassword = encryptedPassword.trim();
    if (normalizedCaptcha.isEmpty || normalizedEncryptedPassword.isEmpty) {
      throw const AcademicIdentityApiException(
        'INVALID_REQUEST',
        '请输入验证码并完成密码加密',
      );
    }
    try {
      final response = await _dio.post(
        challenge.isChange ? '/student-identity/change' : '/student-identity/verify',
        data: <String, Object?>{
          'provider_id': challenge.providerId.value,
          'student_id': challenge.studentId,
          'challenge_token': challengeToken,
          'captcha': normalizedCaptcha,
          'encrypted_password': normalizedEncryptedPassword,
          'school_public_key_fingerprint': fingerprint,
        },
      );
      final data = _requireMap(response, '验证教务身份');
      final providerId = AcademicProviderId.tryParse(
        data['provider_id']?.toString() ?? '',
      );
      final studentId = data['student_id']?.toString().trim() ?? '';
      if (data['verified'] != true ||
          providerId != challenge.providerId ||
          studentId != challenge.studentId) {
        throw const AcademicIdentityApiException(
          'IDENTITY_MISMATCH',
          '学校返回的学生身份与当前绑定不一致',
        );
      }
      if (data['verification_method'] !=
          academicVerificationMethodSchoolProfile) {
        throw const AcademicIdentityApiException(
          'ACADEMIC_BINDING_CONTRACT_ERROR',
          '学生身份验证回执缺少学校核验依据，请更新服务器后重试',
        );
      }
      return AcademicIdentityBinding(
        providerId: providerId!,
        studentId: studentId,
        verified: true,
        verifiedAt: DateTime.tryParse(
          data['verified_at']?.toString() ?? '',
        )?.toUtc(),
        verificationMethod: academicVerificationMethodSchoolProfile,
        verificationVersion: data['verification_version']?.toString(),
        bindingVersion: (data['binding_version'] as num?)?.toInt() ?? 1,
        changedAt: DateTime.tryParse(data['changed_at']?.toString() ?? ''),
      );
    } on AcademicIdentityApiException {
      rethrow;
    } on DioException catch (error) {
      throw _networkError(error, '验证教务身份失败');
    }
  }

  /// 本科 verify-only：密码只在当前 HTTP 请求中传给服务端 pre_verify Provider。
  /// 响应必须携带服务端学校核验后的身份，客户端不接受请求字段回声作为证明。
  Future<AcademicIdentityBinding> verifyUndergraduatePreverify({
    required AcademicIdentityChallenge challenge,
    required String password,
  }) async {
    if (!challenge.isUndergraduatePreverify ||
        challenge.providerId != AcademicProviderId.syluUndergraduate) {
      throw const AcademicIdentityApiException(
        'INVALID_REQUEST',
        '当前身份不是本科 verify-only 契约',
      );
    }
    final normalizedPassword = password;
    if (normalizedPassword.isEmpty) {
      throw const AcademicIdentityApiException(
        'INVALID_REQUEST',
        '请输入教务密码',
      );
    }
    try {
      final response = await _dio.post(
        challenge.isChange ? '/student-identity/change' : _normalizeApiPath(
          challenge.verifyEndpoint,
          fallback: '/student-identity/verify',
        ),
        data: <String, Object?>{
          'provider_id': challenge.providerId.value,
          'student_id': challenge.studentId,
          'password': normalizedPassword,
          if (challenge.isChange) ...{
            'challenge_token': challenge.challengeToken,
            'school_public_key_fingerprint': challenge.schoolPublicKeyFingerprint ?? '',
          },
        },
      );
      final data = _requireMap(response, '验证本科教务身份');
      return _parseVerifiedBinding(
        data,
        expectedProvider: challenge.providerId,
        expectedStudentId: challenge.studentId,
      );
    } on AcademicIdentityApiException {
      rethrow;
    } on DioException catch (error) {
      throw _networkError(error, '验证本科教务身份失败');
    }
  }

  Map<String, dynamic> _requireMap(
      Response<dynamic> response, String operation) {
    final data = response.data;
    if (data is! Map) {
      throw AcademicIdentityApiException(
          'INVALID_RESPONSE', '$operation响应格式无效');
    }
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300) {
      throw AcademicIdentityApiException(
        _errorCode(Map<String, dynamic>.from(data), response.statusCode),
        _errorMessage(Map<String, dynamic>.from(data), operation),
        statusCode: response.statusCode,
      );
    }
    return Map<String, dynamic>.from(data);
  }

  /// 本机声明回执的专用解析器：接受「声明已接收」，拒绝「自称已核验」。
  ///
  /// 身份不一致、回执格式或语义不符合契约，都是契约错误（[AcademicIdentityApiException.isRetryable]
  /// 为 false），不能当成临时网络故障挂定时器重试。
  AcademicIdentityBinding _parseLocalDeclarationBinding(
    Map<String, dynamic> data, {
    required AcademicProviderId expectedProvider,
    required String expectedStudentId,
  }) {
    final providerId = AcademicProviderId.tryParse(
      data['provider_id']?.toString() ?? '',
    );
    final studentId = data['student_id']?.toString().trim() ?? '';
    if (providerId == null ||
        providerId != expectedProvider ||
        studentId != expectedStudentId) {
      throw const AcademicIdentityApiException(
        'IDENTITY_MISMATCH',
        '声明回执的学生身份与本机连接不一致',
      );
    }
    final method = data['verification_method']?.toString();
    if (method != academicVerificationMethodLocalDeclaration) {
      throw const AcademicIdentityApiException(
        'ACADEMIC_BINDING_CONTRACT_ERROR',
        '学生身份同步回执不符合本机声明契约，请更新客户端后重试',
      );
    }
    final assurance = data['assurance_level']?.toString();
    if (assurance != null && assurance != academicAssuranceLocalDeclaration) {
      throw const AcademicIdentityApiException(
        'ACADEMIC_BINDING_CONTRACT_ERROR',
        '学生身份同步回执的依据强度不符合本机声明契约，请更新客户端后重试',
      );
    }
    return AcademicIdentityBinding(
      providerId: providerId,
      studentId: studentId,
      // 本机声明永远不是可信学生认证：即使旧服务端回了 verified=true，
      // 上层也不能据此开放受限功能，所以这里固定为 false。
      verified: false,
      verifiedAt:
          DateTime.tryParse(data['verified_at']?.toString() ?? '')?.toUtc(),
      verificationMethod: method,
      verificationVersion: data['verification_version']?.toString(),
      bindingVersion: (data['binding_version'] as num?)?.toInt() ?? 1,
      changedAt: DateTime.tryParse(data['changed_at']?.toString() ?? ''),
      assuranceLevel: academicAssuranceLocalDeclaration,
    );
  }

  AcademicIdentityBinding _parseVerifiedBinding(
    Map<String, dynamic> data, {
    required AcademicProviderId expectedProvider,
    required String expectedStudentId,
  }) {
    final providerId = AcademicProviderId.tryParse(
      data['provider_id']?.toString() ?? '',
    );
    final studentId = data['student_id']?.toString().trim() ?? '';
    if (data['verified'] != true ||
        providerId != expectedProvider ||
        studentId != expectedStudentId) {
      throw const AcademicIdentityApiException(
        'IDENTITY_MISMATCH',
        '学校返回的学生身份与当前绑定不一致',
      );
    }
    final method = data['verification_method']?.toString();
    if (method != academicVerificationMethodSchoolProfile) {
      throw const AcademicIdentityApiException(
        'ACADEMIC_BINDING_CONTRACT_ERROR',
        '学生身份验证回执缺少学校核验依据，请更新服务器后重试',
      );
    }
    final assurance = data['assurance_level']?.toString();
    if (assurance != null && assurance != academicAssuranceSchoolVerified) {
      throw const AcademicIdentityApiException(
        'ACADEMIC_BINDING_CONTRACT_ERROR',
        '学生身份验证回执的依据强度不符合学校核验契约，请更新服务器后重试',
      );
    }
    return AcademicIdentityBinding(
      providerId: providerId!,
      studentId: studentId,
      verified: true,
      verifiedAt:
          DateTime.tryParse(data['verified_at']?.toString() ?? '')?.toUtc(),
      verificationMethod: method,
      verificationVersion: data['verification_version']?.toString(),
      bindingVersion: (data['binding_version'] as num?)?.toInt() ?? 1,
      changedAt: DateTime.tryParse(data['changed_at']?.toString() ?? ''),
      assuranceLevel: assuranceLevelFor(method),
    );
  }

  AcademicIdentityApiException _networkError(
      DioException error, String message) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    // 未部署的新路由常返回纯文本 404，不能显示成网络或密码错误。
    if (status == 404) {
      return const AcademicIdentityApiException(
        'ACADEMIC_IDENTITY_ROUTE_UNAVAILABLE',
        '服务器暂未开放学生身份验证接口，请联系管理员更新服务后重试，无需修改教务密码',
        statusCode: 404,
      );
    }
    final code = data is Map
        ? _errorCode(Map<String, dynamic>.from(data), status)
        : 'UNAVAILABLE';
    return AcademicIdentityApiException(code, message, statusCode: status);
  }

  String _errorCode(Map<String, dynamic> data, int? status) {
    final code = data['code']?.toString().trim().toUpperCase();
    if (code != null && code.isNotEmpty) return code;
    if (status == 401) return 'AUTHENTICATION_REQUIRED';
    if (status == 429) return 'RATE_LIMIT';
    if (status != null && status >= 500) return 'UNAVAILABLE';
    return 'REQUEST_FAILED';
  }

  String _errorMessage(Map<String, dynamic> data, String operation) {
    final code = data['code']?.toString().trim().toUpperCase();
    return switch (code) {
      'ACADEMIC_CHALLENGE_REJECTED' => '教务验证码或挑战无效，请刷新后重试',
      'ACADEMIC_CREDENTIAL_REJECTED' => '教务密码需要更新',
      'ACADEMIC_ACCOUNT_REJECTED' => '教务账号无法识别',
      'ACADEMIC_ACCOUNT_RESTRICTED' => '教务账号当前受限',
      'ACADEMIC_IDENTITY_MISMATCH' => '学校返回的学生身份与当前绑定不一致',
      'ACADEMIC_IDENTITY_UNVERIFIED' => '学校尚未确认该教务身份，请重新绑定',
      'ACADEMIC_CHALLENGE_REPLAYED' => '教务挑战已使用，请刷新后重试',
      'ACADEMIC_RATE_LIMITED' || 'ACADEMIC_RATE_LIMIT' => '教务请求过于频繁，请稍后再试',
      'ACADEMIC_PROVIDER_UNAVAILABLE' => '研究生教务验证暂不可用',
      _ => '$operation失败，请稍后重试',
    };
  }

  List<int>? _decodeBase64(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;
    final comma = value.indexOf(',');
    final encoded = comma >= 0 ? value.substring(comma + 1) : value;
    try {
      return base64Decode(encoded);
    } on FormatException {
      return null;
    }
  }

  String _normalizeApiPath(Object? raw, {required String fallback}) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return fallback;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return fallback;
    var path = uri.path;
    if (path == '/api') return '/';
    if (path.startsWith('/api/')) path = path.substring('/api'.length);
    if (!path.startsWith('/')) path = '/$path';
    return path;
  }
}
