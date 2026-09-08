import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 稳定的教务实现标识。展示文案不能参与协议路由。
enum AcademicProviderId {
  syluUndergraduate('sylu_undergraduate', '本科教务'),
  syluGraduate('sylu_graduate', '研究生教务');

  const AcademicProviderId(this.value, this.displayName);

  final String value;
  final String displayName;

  static AcademicProviderId? tryParse(String value) {
    final normalized = value.trim().toLowerCase();
    for (final id in values) {
      if (id.value == normalized) return id;
    }
    return null;
  }
}

/// 教务身份的完整边界。学号本身不能决定 Provider。
final class AcademicIdentityKey {
  const AcademicIdentityKey({
    required this.appUserId,
    required this.providerId,
    required this.studentId,
  });

  final String appUserId;
  final AcademicProviderId providerId;
  final String studentId;

  bool get isValid =>
      appUserId.trim().isNotEmpty && studentId.trim().isNotEmpty;

  String get canonical =>
      '${appUserId.trim()}|${providerId.value}|${studentId.trim()}';

  /// 物理存储使用不可逆标识，避免把完整学号写入文件名和 item name。
  String get storageId => _sha256(canonical);

  bool sameIdentity(AcademicIdentityKey other) =>
      appUserId.trim() == other.appUserId.trim() &&
      providerId == other.providerId &&
      studentId.trim() == other.studentId.trim();

  @override
  bool operator ==(Object other) =>
      other is AcademicIdentityKey && sameIdentity(other);

  @override
  int get hashCode =>
      Object.hash(appUserId.trim(), providerId, studentId.trim());

  @override
  String toString() => 'AcademicIdentityKey(${providerId.value}, <redacted>)';
}

/// Provider 的已实测能力。未完成探针/解析的功能必须保持 false。
final class AcademicProviderCapabilities {
  const AcademicProviderCapabilities({
    this.timetable = false,
    this.grades = false,
    this.exams = false,
    this.gpa = false,
    this.captcha = false,
    this.localCaptchaRecognition = false,
  });

  final bool timetable;
  final bool grades;
  final bool exams;
  final bool gpa;
  final bool captcha;
  final bool localCaptchaRecognition;
}

sealed class AcademicLoginChallenge {
  const AcademicLoginChallenge();
}

final class NoLoginChallenge extends AcademicLoginChallenge {
  const NoLoginChallenge();
}

final class ImageCaptchaChallenge extends AcademicLoginChallenge {
  ImageCaptchaChallenge({
    required Uint8List imageBytes,
    required this.challengeId,
    this.createdAt,
    this.suggestedCode,
    this.suggestionConfidence,
  }) : imageBytes = Uint8List.fromList(imageBytes);

  final Uint8List imageBytes;
  final String challengeId;
  final DateTime? createdAt;
  final String? suggestedCode;
  final double? suggestionConfidence;
}

final class AcademicLoginRequest {
  const AcademicLoginRequest({
    required this.studentId,
    required this.password,
    this.captchaCode,
    this.challengeId,
  });

  final String studentId;
  final String password;
  final String? captchaCode;
  final String? challengeId;
}

sealed class AcademicLoginResult {
  const AcademicLoginResult();
}

final class AcademicLoginSucceeded extends AcademicLoginResult {
  const AcademicLoginSucceeded({required this.studentId});

  final String studentId;
}

final class AcademicLoginChallengeRequired extends AcademicLoginResult {
  const AcademicLoginChallengeRequired({required this.challenge});

  final AcademicLoginChallenge challenge;
}

final class AcademicLoginRejected extends AcademicLoginResult {
  const AcademicLoginRejected({required this.error});

  final AcademicAuthFailure error;
}

final class AcademicTerm {
  const AcademicTerm({
    required this.providerId,
    required this.providerTermId,
    required this.displayName,
    this.isCurrent = false,
    this.localYear,
    this.localSemester,
  });

  final AcademicProviderId providerId;
  final String providerTermId;
  final String displayName;
  final bool isCurrent;

  /// 可安全映射到旧课表缓存契约的学年和学期编码；未知时保持为空。
  final String? localYear;
  final int? localSemester;
}

/// 统一课表领域模型。Provider 原始字段只能在适配器内出现。
final class AcademicSchedule {
  AcademicSchedule({required Iterable<AcademicScheduleOccurrence> occurrences})
      : occurrences = List.unmodifiable(occurrences);

  final List<AcademicScheduleOccurrence> occurrences;
}

final class AcademicScheduleOccurrence {
  const AcademicScheduleOccurrence({
    required this.courseName,
    required this.teacher,
    required this.location,
    required this.dayOfWeek,
    required this.periodOrder,
    required this.periodLabel,
    required this.weekExpression,
    this.providerMetadata = const <String, Object?>{},
  });

  final String courseName;
  final String teacher;
  final String location;
  final int dayOfWeek;
  final int periodOrder;
  final String periodLabel;
  final String weekExpression;
  final Map<String, Object?> providerMetadata;
}

/// Provider 会话工厂。Registry 只保留工厂，不缓存任何会话对象。
abstract interface class AcademicProviderFactory {
  AcademicProviderId get id;

  AcademicProvider create(AcademicIdentityKey identity);
}

abstract interface class AcademicProvider {
  AcademicIdentityKey get identity;
  AcademicProviderId get id;
  AcademicProviderCapabilities get capabilities;

  Future<AcademicLoginChallenge> prepareLogin();

  Future<AcademicLoginResult> login(AcademicLoginRequest request);

  Future<void> restoreSession(ProviderSessionArtifact artifact);

  Future<AcademicSessionProbeResult> probeSession();

  Future<List<AcademicTerm>> fetchTerms();

  Future<AcademicSchedule> fetchSchedule(String providerTermId);

  Future<ProviderSessionArtifact?> exportSession();

  Future<void> clearSession();

  void close();
}

final class AcademicSessionProbeResult {
  const AcademicSessionProbeResult({
    required this.authenticated,
    this.confirmedStudentId,
  });

  final bool authenticated;
  final String? confirmedStudentId;
}

/// Provider 持有的敏感会话材料，仅允许进入本机加密保险箱，不得写日志或上传 AI。
final class ProviderSessionArtifact {
  const ProviderSessionArtifact({
    required this.providerId,
    required this.studentId,
    required this.artifactVersion,
    required this.createdAt,
    required this.validatedAt,
    required this.opaqueProviderState,
    this.maxRestoreAge,
  });

  final AcademicProviderId providerId;
  final String studentId;
  final int artifactVersion;
  final DateTime createdAt;
  final DateTime? validatedAt;
  final Duration? maxRestoreAge;
  final Map<String, Object?> opaqueProviderState;

  bool get isRestoreAgeValid {
    final maxAge = maxRestoreAge;
    return maxAge == null ||
        DateTime.now().toUtc().difference(createdAt.toUtc()) <= maxAge;
  }
}

/// 单一身份到工厂的注册表；重复注册直接失败，避免悄悄替换协议。
final class AcademicProviderRegistry {
  AcademicProviderRegistry([Iterable<AcademicProviderFactory>? factories]) {
    for (final factory in factories ?? const <AcademicProviderFactory>[]) {
      final previous = _factories[factory.id];
      if (previous != null) {
        throw StateError('重复注册教务 Provider: ${factory.id.value}');
      }
      _factories[factory.id] = factory;
    }
  }

  final Map<AcademicProviderId, AcademicProviderFactory> _factories =
      <AcademicProviderId, AcademicProviderFactory>{};

  Iterable<AcademicProviderId> get ids => _factories.keys;

  AcademicProvider create(AcademicIdentityKey identity) {
    final factory = _factories[identity.providerId];
    if (factory == null) {
      throw StateError('未注册教务 Provider: ${identity.providerId.value}');
    }
    return factory.create(identity);
  }

  AcademicProviderFactory? factoryFor(AcademicProviderId id) => _factories[id];
}

enum AcademicAuthFailureType {
  credentialMissing,
  credentialRejected,
  accountRejected,
  accountRestricted,
  challengeRequired,
  challengeRejected,
  authRejectedAmbiguous,
  sessionExpired,
  identityMismatch,
}

final class AcademicAuthFailure implements Exception {
  const AcademicAuthFailure(this.type, this.message, {this.providerCode});

  final AcademicAuthFailureType type;
  final String message;
  final String? providerCode;

  @override
  String toString() => 'AcademicAuthFailure(${type.name})';
}

String _sha256(String value) {
  // 仅用于物理分区命名；真正的密钥仍由 Secure Store 生成和保存。
  return sha256.convert(utf8.encode(value)).toString();
}
