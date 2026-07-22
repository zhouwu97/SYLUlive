import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/config/beta_release_policy.dart';

enum AIFeatureFlag {
  chat,
  customProvider,
  personalGateway,
  personalSkills,
  toolCalling,
  academicEngine,
  graduationAssistant,
  competitionFit,
}

extension AIFeatureFlagKey on AIFeatureFlag {
  String get storageKey => switch (this) {
        AIFeatureFlag.chat => 'ai_chat_enabled',
        AIFeatureFlag.customProvider => 'ai_custom_provider_enabled',
        AIFeatureFlag.personalGateway => 'ai_personal_gateway_enabled',
        AIFeatureFlag.personalSkills => 'ai_personal_skills_enabled',
        AIFeatureFlag.toolCalling => 'ai_tool_calling_enabled',
        AIFeatureFlag.academicEngine => 'ai_academic_engine_enabled',
        AIFeatureFlag.graduationAssistant => 'ai_graduation_assistant_enabled',
        AIFeatureFlag.competitionFit => 'ai_competition_fit_enabled',
      };

  /// 发布策略关闭的功能不能被历史本地开关重新开启。
  bool get availableInCurrentRelease => switch (this) {
        AIFeatureFlag.graduationAssistant =>
          BetaReleasePolicy.aiGraduationAssistant,
        AIFeatureFlag.competitionFit => BetaReleasePolicy.aiCompetitionFit,
        _ => true,
      };
}

class AIFeatureFlagStore {
  AIFeatureFlagStore({
    Future<AppPreferencesStore> Function()? preferencesLoader,
  }) : _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  final Future<AppPreferencesStore> Function() _preferencesLoader;

  Future<bool> isEnabled(AIFeatureFlag flag) async {
    if (!flag.availableInCurrentRelease) return false;
    final preferences = await _preferencesLoader();
    return preferences.getBool(flag.storageKey) ?? true;
  }

  Future<Map<AIFeatureFlag, bool>> readAll() async {
    final preferences = await _preferencesLoader();
    return <AIFeatureFlag, bool>{
      for (final flag in AIFeatureFlag.values)
        flag: flag.availableInCurrentRelease
            ? preferences.getBool(flag.storageKey) ?? true
            : false,
    };
  }

  Future<void> setEnabled(AIFeatureFlag flag, bool enabled) async {
    if (enabled && !flag.availableInCurrentRelease) {
      throw StateError('该 AI 功能在当前内测版本中暂未开放');
    }
    final preferences = await _preferencesLoader();
    final saved = await preferences.setBool(flag.storageKey, enabled);
    if (!saved) throw StateError('AI 功能开关保存失败');
  }

  Future<void> disablePersonalCapabilities() async {
    for (final flag in const <AIFeatureFlag>[
      AIFeatureFlag.personalGateway,
      AIFeatureFlag.personalSkills,
      AIFeatureFlag.toolCalling,
      AIFeatureFlag.academicEngine,
      AIFeatureFlag.graduationAssistant,
      AIFeatureFlag.competitionFit,
    ]) {
      await setEnabled(flag, false);
    }
  }
}
