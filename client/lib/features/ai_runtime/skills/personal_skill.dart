import '../../campus_data/storage/personal_snapshot_models.dart';
import 'skill_execution_context.dart';

enum SkillSensitivity { publicData, low, medium, high }

enum SkillStatus {
  success,
  partial,
  missingData,
  needsRefresh,
  invalidInput,
  denied,
  unavailable,
  failed,
  unknownSkill,
}

/// Skill 结果所使用的数据来源与时间证据。
class SkillEvidence {
  const SkillEvidence({
    required this.source,
    required this.scope,
    this.dataType,
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
  });

  final String source;
  final String scope;
  final PersonalDataType? dataType;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
}

/// Skill 的统一、不可变输出，不携带异常对象或原始 Gateway Payload。
class SkillResult<T> {
  SkillResult({
    required this.status,
    required this.containsPersonalData,
    this.value,
    List<SkillEvidence> evidence = const <SkillEvidence>[],
    List<String> warnings = const <String>[],
  })  : evidence = List<SkillEvidence>.unmodifiable(evidence),
        warnings = List<String>.unmodifiable(warnings);

  final T? value;
  final SkillStatus status;
  final List<SkillEvidence> evidence;
  final List<String> warnings;
  final bool containsPersonalData;

  bool get isSuccess =>
      status == SkillStatus.success || status == SkillStatus.partial;

  SkillResult<R> castValue<R>() => SkillResult<R>(
        value: value as R?,
        status: status,
        evidence: evidence,
        warnings: warnings,
        containsPersonalData: containsPersonalData,
      );
}

abstract interface class PersonalSkill<I, O> {
  String get id;

  SkillSensitivity get sensitivity;

  Set<PersonalDataType> get requiredDataTypes;

  Future<SkillResult<O>> execute(I input, SkillExecutionContext context);
}
