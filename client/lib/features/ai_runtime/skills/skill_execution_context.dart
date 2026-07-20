import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/gateway/gateway_result.dart';
import '../personal_data/gateway/personal_data_gateway.dart';
import '../personal_data/models/academic_overview.dart';
import '../personal_data/models/academic_records.dart';
import '../personal_data/models/erke_overview.dart';
import '../personal_data/models/physical_overview.dart';
import '../personal_data/models/schedule_overview.dart';

class SkillDataAccessViolation implements Exception {
  const SkillDataAccessViolation(this.dataType);

  final PersonalDataType dataType;
}

/// Skill 的能力对象。注册表会按声明的数据类型生成受限副本。
class SkillExecutionContext {
  SkillExecutionContext({
    required PersonalDataGateway personalDataGateway,
    DateTime Function()? clock,
  })  : _personalDataGateway = personalDataGateway,
        _clock = clock ?? DateTime.now,
        _allowedDataTypes = Set<PersonalDataType>.of(PersonalDataType.values),
        _accessedDataTypes = <PersonalDataType>{};

  SkillExecutionContext._(
    this._personalDataGateway,
    this._clock,
    Set<PersonalDataType> allowedDataTypes,
    this._accessedDataTypes,
  ) : _allowedDataTypes = Set<PersonalDataType>.unmodifiable(allowedDataTypes);

  final PersonalDataGateway _personalDataGateway;
  final DateTime Function() _clock;
  final Set<PersonalDataType> _allowedDataTypes;
  final Set<PersonalDataType> _accessedDataTypes;

  DateTime now() => _clock();

  Set<PersonalDataType> get accessedDataTypes =>
      Set<PersonalDataType>.unmodifiable(_accessedDataTypes);

  SkillExecutionContext restrictTo(Set<PersonalDataType> dataTypes) =>
      SkillExecutionContext._(
        _personalDataGateway,
        _clock,
        _allowedDataTypes.intersection(dataTypes),
        _accessedDataTypes,
      );

  Future<GatewayResult<ErkeOverview>> getErkeOverview() {
    _recordAccess(PersonalDataType.erke);
    return _personalDataGateway.getErkeOverview();
  }

  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview() {
    _recordAccess(PersonalDataType.physical);
    return _personalDataGateway.getPhysicalOverview();
  }

  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  }) {
    _recordAccess(PersonalDataType.schedule);
    return _personalDataGateway.getScheduleOverview(start: start, end: end);
  }

  Future<GatewayResult<AcademicOverview>> getAcademicOverview() {
    _recordAccess(PersonalDataType.academic);
    return _personalDataGateway.getAcademicOverview();
  }

  Future<GatewayResult<AcademicRecords>> getAcademicRecords() {
    _recordAccess(PersonalDataType.academic);
    return _personalDataGateway.getAcademicRecords();
  }

  void _recordAccess(PersonalDataType dataType) {
    if (!_allowedDataTypes.contains(dataType)) {
      throw SkillDataAccessViolation(dataType);
    }
    _accessedDataTypes.add(dataType);
  }
}
