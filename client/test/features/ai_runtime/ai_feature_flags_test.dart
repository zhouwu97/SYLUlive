import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/ai_feature_flags.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      'ai_graduation_assistant_enabled': true,
      'ai_competition_fit_enabled': true,
      'ai_academic_engine_enabled': true,
    });
  });

  test('发布策略优先于历史本地开关', () async {
    final store = AIFeatureFlagStore();

    expect(await store.isEnabled(AIFeatureFlag.graduationAssistant), isFalse);
    expect(await store.isEnabled(AIFeatureFlag.competitionFit), isFalse);
    expect(await store.isEnabled(AIFeatureFlag.academicEngine), isTrue);
  });

  test('当前内测版不能重新开启冻结能力', () async {
    final store = AIFeatureFlagStore();

    await expectLater(
      store.setEnabled(AIFeatureFlag.graduationAssistant, true),
      throwsStateError,
    );
    await expectLater(
      store.setEnabled(AIFeatureFlag.competitionFit, true),
      throwsStateError,
    );
  });
}
