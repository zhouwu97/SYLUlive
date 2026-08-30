import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/erke_cache_store.dart';
import 'package:shenliyuan/features/personal_data_sync/erke_snapshot_upload.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_coordinator.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_result.dart';
import 'package:shenliyuan/services/webvpn_service.dart';

void main() {
  test('设备任务触发的二课刷新在“每次询问”策略下按单次授权上传，不改写策略', () async {
    final policyStore = _FakePolicyStore(ErkeSnapshotUploadPolicy.askEveryUpdate);
    final uploader = _RecordingUploader();
    final gateway = _gateway(policyStore, uploader);

    final result = await gateway.syncErke(automationUpload: true);

    expect(result.status, PersonalSyncItemStatus.success);
    expect(uploader.uploads, 1);
    expect(policyStore.writes, 0, reason: '自动化上传不得改写用户保存的策略');
    expect(result.message, contains('已按授权上传'));
  });

  test('“从不上传”策略在设备任务自动化刷新时仍然生效', () async {
    final policyStore =
        _FakePolicyStore(ErkeSnapshotUploadPolicy.neverUpload);
    final uploader = _RecordingUploader();
    final gateway = _gateway(policyStore, uploader);

    final result = await gateway.syncErke(automationUpload: true);

    expect(result.status, PersonalSyncItemStatus.success);
    expect(uploader.uploads, 0);
    expect(result.message, contains('保留二课摘要在本机'));
  });

  test('普通同步路径不受自动化放行影响，每次询问仍跳过上传', () async {
    final policyStore =
        _FakePolicyStore(ErkeSnapshotUploadPolicy.askEveryUpdate);
    final uploader = _RecordingUploader();
    final gateway = _gateway(policyStore, uploader);

    final result = await gateway.syncErke();

    expect(result.status, PersonalSyncItemStatus.success);
    expect(uploader.uploads, 0);
    expect(result.message, contains('下次更新时会再次询问'));
  });
}

ErkeRepositoryPersonalSyncGateway _gateway(
  _FakePolicyStore policyStore,
  _RecordingUploader uploader,
) {
  return ErkeRepositoryPersonalSyncGateway(
    repository: _StubErkeRepository(),
    requestCredentials: () async => const PersonalErkeCredentials(
      studentId: '20210001',
      casPassword: 'cas-password',
      erkePassword: 'erke-password',
    ),
    snapshotUploader: uploader,
    uploadPolicyStore: policyStore,
    automationUploadAllowed: true,
    now: () => DateTime.utc(2026, 8, 28, 12),
  );
}

class _StubErkeRepository extends ErkeRepository {
  _StubErkeRepository()
      : super(vpnService: WebVpnService(), cacheStore: _UnusedErkeCacheStore());

  @override
  Future<bool> loginAndFetch(
    String studentId,
    String casPassword,
    String erkePassword,
  ) async =>
      true;

  @override
  Future<ErkeSnapshot?> readSnapshotForAuthorizedUpload() async =>
      const ErkeSnapshot(
        graduation: ErkeGraduationSummary(
          requiredTotal: 60,
          earnedTotal: 42.5,
          rawTotalGap: 17.5,
          categoryGap: 4,
          graduationGap: 17.5,
          unmetCount: 1,
          officialConclusion: '未达标',
          categories: <ErkeRequirementCategory>[],
        ),
        fetchedAt: null,
      );
}

class _UnusedErkeCacheStore extends ErkeCacheStore {
  _UnusedErkeCacheStore()
      : super(appUserId: 'test-user', sourceAccountId: 'test-account');
}

class _RecordingUploader extends ErkeSnapshotUploadGateway {
  _RecordingUploader() : super(Dio());

  int uploads = 0;

  @override
  Future<void> upload(ErkeSnapshot snapshot) async {
    uploads++;
  }
}

class _FakePolicyStore implements ErkeSnapshotUploadPolicyStore {
  _FakePolicyStore(this.policy);

  ErkeSnapshotUploadPolicy policy;
  int writes = 0;

  @override
  Future<ErkeSnapshotUploadPolicy> read() async => policy;

  @override
  Future<void> write(ErkeSnapshotUploadPolicy policy) async {
    writes++;
    this.policy = policy;
  }
}
