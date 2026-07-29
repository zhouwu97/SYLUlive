import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_source.dart';
import 'package:shenliyuan/features/personal_data_sync/personal_data_sync_models.dart';

void main() {
  test('个人数据来源使用跨端稳定 wire 值', () {
    expect(PersonalDataSource.deviceEncryptedCache.wireValue,
        'device_encrypted_cache');
    expect(PersonalDataSourceWireValue.fromWireValue('server_snapshot'),
        PersonalDataSource.serverSnapshot);
    expect(PersonalDataSource.localEncryptedVault,
        PersonalDataSource.deviceEncryptedCache);
  });

  test('结果信封始终包含来源、时间状态和证据字段', () {
    final fetchedAt = DateTime.utc(2026, 7, 25, 1, 20);
    final result = PersonalDataResult<Map<String, Object?>>(
      data: <String, Object?>{'failed_course_count': 2},
      status: PersonalDataStatus.available,
      source: PersonalDataSource.serverSnapshot,
      fetchedAt: fetchedAt,
      evidence: <PersonalDataEvidence>[
        PersonalDataEvidence(
          source: PersonalDataSource.serverSnapshot,
          dataset: 'grades',
          fetchedAt: fetchedAt,
        ),
      ],
    );

    final json = result.toJson((value) => value);
    expect(json['data'], <String, Object?>{'failed_course_count': 2});
    expect(json['source'], 'server_snapshot');
    expect(json['is_stale'], isFalse);
    expect(json['is_partial'], isFalse);
    expect(json['warnings'], isEmpty);
    expect(json['evidence'], hasLength(1));
  });
}
