import 'package:flutter/material.dart';

import '../../features/ai_runtime/ai_feature_flags.dart';

class AIFeatureSettingsScreen extends StatefulWidget {
  const AIFeatureSettingsScreen({super.key});

  @override
  State<AIFeatureSettingsScreen> createState() =>
      _AIFeatureSettingsScreenState();
}

class _AIFeatureSettingsScreenState extends State<AIFeatureSettingsScreen> {
  final AIFeatureFlagStore _store = AIFeatureFlagStore();
  Map<AIFeatureFlag, bool>? _values;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await _store.readAll();
    if (mounted) setState(() => _values = values);
  }

  Future<void> _set(AIFeatureFlag flag, bool enabled) async {
    await _store.setEnabled(flag, enabled);
    if (!mounted) return;
    setState(() => _values = <AIFeatureFlag, bool>{..._values!, flag: enabled});
  }

  @override
  Widget build(BuildContext context) {
    final values = _values;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 功能开关')),
      body: values == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: AIFeatureFlag.values
                  .map(
                    (flag) => SwitchListTile(
                      title: Text(_label(flag)),
                      subtitle: flag.availableInCurrentRelease
                          ? null
                          : const Text('内测阶段暂不开放'),
                      secondary: Icon(_icon(flag)),
                      value: values[flag]!,
                      onChanged: flag.availableInCurrentRelease
                          ? (enabled) => _set(flag, enabled)
                          : null,
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }

  String _label(AIFeatureFlag flag) => switch (flag) {
        AIFeatureFlag.chat => '校园 AI 问答',
        AIFeatureFlag.customProvider => '自定义模型',
        AIFeatureFlag.personalGateway => '个人数据 Gateway',
        AIFeatureFlag.personalSkills => '个人 Skills',
        AIFeatureFlag.toolCalling => 'Tool Calling',
        AIFeatureFlag.academicEngine => '学业计算引擎',
        AIFeatureFlag.graduationAssistant => '毕业助手',
        AIFeatureFlag.competitionFit => '个性化竞赛适配',
      };

  IconData _icon(AIFeatureFlag flag) => switch (flag) {
        AIFeatureFlag.chat => Icons.chat_outlined,
        AIFeatureFlag.customProvider => Icons.hub_outlined,
        AIFeatureFlag.personalGateway => Icons.lock_outline,
        AIFeatureFlag.personalSkills => Icons.extension_outlined,
        AIFeatureFlag.toolCalling => Icons.build_outlined,
        AIFeatureFlag.academicEngine => Icons.calculate_outlined,
        AIFeatureFlag.graduationAssistant => Icons.fact_check_outlined,
        AIFeatureFlag.competitionFit => Icons.emoji_events_outlined,
      };
}
