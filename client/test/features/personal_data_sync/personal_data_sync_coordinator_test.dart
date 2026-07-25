import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_source.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_coordinator.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_models.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_progress.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_result.dart';

void main() {
  test('同步按教务后二课的顺序运行，单项失败不会回滚其他项', () async {
    final calls = <String>[];
    final progress = <PersonalSyncProgress>[];
    final coordinator = PersonalDataSyncCoordinator(
      academicGateway: _FakeAcademicGateway(calls),
      erkeGateway: _FakeErkeGateway(calls),
    );

    final result = await coordinator.sync(
      datasets: const <PersonalSyncDataset>{
        PersonalSyncDataset.grades,
        PersonalSyncDataset.schedule,
        PersonalSyncDataset.erke,
      },
      trigger: PersonalSyncTrigger.assistant,
      onProgress: progress.add,
    );

    expect(calls, <String>['schedule', 'grades', 'erke']);
    expect(result.items[PersonalSyncDataset.schedule]!.status,
        PersonalSyncItemStatus.success);
    expect(result.items[PersonalSyncDataset.grades]!.status,
        PersonalSyncItemStatus.failed);
    expect(result.items[PersonalSyncDataset.erke]!.status,
        PersonalSyncItemStatus.success);
    expect(result.hasFailures, isTrue);
    expect(progress.where((item) => item.isRunning), hasLength(3));
  });

  test('没有二课适配器时仅跳过二课，不影响已请求的教务数据', () async {
    final calls = <String>[];
    final coordinator = PersonalDataSyncCoordinator(
      academicGateway: _FakeAcademicGateway(calls),
    );

    final result = await coordinator.sync(
      datasets: const <PersonalSyncDataset>{
        PersonalSyncDataset.academicSituation,
        PersonalSyncDataset.erke,
      },
      trigger: PersonalSyncTrigger.vault,
    );

    expect(calls, <String>['academicSituation']);
    expect(result.items[PersonalSyncDataset.erke]!.status,
        PersonalSyncItemStatus.skipped);
  });
}

class _FakeAcademicGateway implements PersonalAcademicSyncGateway {
  _FakeAcademicGateway(this.calls);

  final List<String> calls;

  @override
  Future<PersonalSyncItemResult> syncAcademicSituation() async {
    calls.add('academicSituation');
    return _success(PersonalSyncDataset.academicSituation);
  }

  @override
  Future<PersonalSyncItemResult> syncCreditRequirements() async {
    calls.add('creditRequirements');
    return _success(PersonalSyncDataset.creditRequirements);
  }

  @override
  Future<PersonalSyncItemResult> syncGrades() async {
    calls.add('grades');
    return const PersonalSyncItemResult(
      dataset: PersonalSyncDataset.grades,
      status: PersonalSyncItemStatus.failed,
      source: PersonalDataSource.none,
      message: '教务服务超时',
    );
  }

  @override
  Future<PersonalSyncItemResult> syncSchedule() async {
    calls.add('schedule');
    return _success(PersonalSyncDataset.schedule);
  }
}

class _FakeErkeGateway implements PersonalErkeSyncGateway {
  _FakeErkeGateway(this.calls);

  final List<String> calls;

  @override
  Future<PersonalSyncItemResult> syncErke() async {
    calls.add('erke');
    return _success(PersonalSyncDataset.erke);
  }
}

PersonalSyncItemResult _success(PersonalSyncDataset dataset) =>
    PersonalSyncItemResult(
      dataset: dataset,
      status: PersonalSyncItemStatus.success,
      source: PersonalDataSource.remoteEduFetch,
    );
