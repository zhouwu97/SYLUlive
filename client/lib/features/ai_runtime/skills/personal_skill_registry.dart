import '../../campus_data/storage/personal_snapshot_models.dart';
import 'personal_skill.dart';
import 'skill_execution_context.dart';

class PersonalSkillRegistry {
  PersonalSkillRegistry(Iterable<PersonalSkill<dynamic, dynamic>> skills)
      : _skills = _buildRegistry(skills);

  final Map<String, PersonalSkill<dynamic, dynamic>> _skills;

  Set<String> get registeredSkillIds =>
      Set<String>.unmodifiable(_skills.keys.toSet());

  bool contains(String id) => _skills.containsKey(id);

  SkillSensitivity? sensitivityFor(String id) => _skills[id]?.sensitivity;

  Set<PersonalDataType>? requiredDataTypesFor(String id) {
    final dataTypes = _skills[id]?.requiredDataTypes;
    return dataTypes == null
        ? null
        : Set<PersonalDataType>.unmodifiable(dataTypes);
  }

  /// 未知 ID、输入类型错误和越权读取均失败关闭，不抛出个人数据异常。
  Future<SkillResult<Object?>> execute({
    required String id,
    required Object? input,
    required SkillExecutionContext context,
  }) async {
    final skill = _skills[id];
    if (skill == null) {
      return SkillResult<Object?>(
        status: SkillStatus.unknownSkill,
        containsPersonalData: false,
        warnings: const <String>['请求的 Skill 未注册'],
      );
    }

    final restricted = context.restrictTo(skill.requiredDataTypes);
    try {
      final dynamic result = await skill.execute(input, restricted);
      if (result is! SkillResult) {
        return _failedResult();
      }
      final undeclared = restricted.accessedDataTypes
          .difference(skill.requiredDataTypes)
          .isNotEmpty;
      if (undeclared) {
        return SkillResult<Object?>(
          status: SkillStatus.denied,
          containsPersonalData: false,
          warnings: const <String>['Skill 尝试读取未声明的数据类型'],
        );
      }
      final invalidEvidence = result.evidence.any(
        (SkillEvidence evidence) =>
            evidence.source.trim().isEmpty ||
            evidence.fetchedAt == null ||
            (evidence.dataType != null &&
                !skill.requiredDataTypes.contains(evidence.dataType)),
      );
      if (result.isSuccess &&
          result.value != null &&
          (result.evidence.isEmpty || invalidEvidence)) {
        return SkillResult<Object?>(
          status: SkillStatus.failed,
          containsPersonalData: false,
          warnings: const <String>['Skill 结果缺少有效来源证据'],
        );
      }
      return SkillResult<Object?>(
        value: result.value,
        status: result.status,
        evidence: List<SkillEvidence>.from(result.evidence),
        warnings: List<String>.from(result.warnings),
        containsPersonalData: result.containsPersonalData ||
            (result.value != null && skill.requiredDataTypes.isNotEmpty),
      );
    } on SkillDataAccessViolation {
      return SkillResult<Object?>(
        status: SkillStatus.denied,
        containsPersonalData: false,
        warnings: const <String>['Skill 尝试读取未声明的数据类型'],
      );
    } on TypeError {
      return SkillResult<Object?>(
        status: SkillStatus.invalidInput,
        containsPersonalData: false,
        warnings: const <String>['Skill 输入类型无效'],
      );
    } catch (_) {
      return _failedResult();
    }
  }

  static Map<String, PersonalSkill<dynamic, dynamic>> _buildRegistry(
    Iterable<PersonalSkill<dynamic, dynamic>> skills,
  ) {
    final result = <String, PersonalSkill<dynamic, dynamic>>{};
    for (final skill in skills) {
      final id = skill.id.trim();
      if (id.isEmpty || result.containsKey(id)) {
        throw ArgumentError('Skill ID 为空或重复');
      }
      result[id] = skill;
    }
    return Map<String, PersonalSkill<dynamic, dynamic>>.unmodifiable(result);
  }

  static SkillResult<Object?> _failedResult() => SkillResult<Object?>(
        status: SkillStatus.failed,
        containsPersonalData: false,
        warnings: const <String>['Skill 执行失败'],
      );
}
