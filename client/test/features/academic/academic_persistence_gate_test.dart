import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';

void main() {
  test('Registry 未初始化时默认拒绝读写', () {
    const userId = 'unknown-academic-user';
    AcademicPersistenceRegistry.clear(userId);
    final gate = RegistryAcademicPersistenceGate(userId);

    expect(gate.allowPersonalDataPersistence, isFalse);
    expect(gate.allowPersonalDataRead, isFalse);
  });

  test('Registry 明确启用后允许读写', () {
    const userId = 'enabled-academic-user';
    AcademicPersistenceRegistry.set(userId, enabled: true);
    addTearDown(() => AcademicPersistenceRegistry.clear(userId));
    final gate = RegistryAcademicPersistenceGate(userId);

    expect(gate.allowPersonalDataPersistence, isTrue);
    expect(gate.allowPersonalDataRead, isTrue);
  });
}
