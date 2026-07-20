import 'package:shared_preferences/shared_preferences.dart';

enum AIFeatureFlag {
  chat,
  customProvider,
  personalGateway,
  personalSkills,
  toolCalling,
  academicEngine,
  graduationAssistant,
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
      };
}

class AIFeatureFlagStore {
  AIFeatureFlagStore({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferencesLoader;

  Future<bool> isEnabled(AIFeatureFlag flag) async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(flag.storageKey) ?? true;
  }

  Future<Map<AIFeatureFlag, bool>> readAll() async {
    final preferences = await _preferencesLoader();
    return <AIFeatureFlag, bool>{
      for (final flag in AIFeatureFlag.values)
        flag: preferences.getBool(flag.storageKey) ?? true,
    };
  }

  Future<void> setEnabled(AIFeatureFlag flag, bool enabled) async {
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
    ]) {
      await setEnabled(flag, false);
    }
  }
}
