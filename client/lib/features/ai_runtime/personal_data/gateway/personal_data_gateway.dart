import '../models/academic_overview.dart';
import '../models/academic_records.dart';
import '../models/erke_overview.dart';
import '../models/physical_overview.dart';
import '../models/schedule_overview.dart';
import 'gateway_result.dart';

/// AI 个人数据的唯一只读入口。
abstract interface class PersonalDataGateway {
  Future<GatewayResult<ErkeOverview>> getErkeOverview();

  Future<GatewayResult<PhysicalOverview>> getPhysicalOverview();

  Future<GatewayResult<ScheduleOverview>> getScheduleOverview({
    required DateTime start,
    required DateTime end,
  });

  Future<GatewayResult<AcademicOverview>> getAcademicOverview();

  Future<GatewayResult<AcademicRecords>> getAcademicRecords();

  Future<void> close();
}
