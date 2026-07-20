import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import '../../features/ai_runtime/ai_feature_flags.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/deterministic/competition_fit_engine.dart';
import '../../features/ai_runtime/deterministic/graduation_requirement_engine.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_account_context.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import '../../features/ai_runtime/skills/competition_search_skill.dart';
import '../../features/ai_runtime/skills/deterministic_skills.dart';
import '../../features/ai_runtime/skills/personal_skill.dart';
import '../../features/ai_runtime/skills/skill_execution_context.dart';
import '../../features/ai_runtime/skills/stage_seven_skill_registry.dart';
import '../../features/ai_runtime/tool_calling/openai_tool_calling_model.dart';
import '../../features/ai_runtime/tool_calling/tool_call_models.dart';
import '../../features/ai_runtime/tool_calling/tool_definitions.dart';
import '../../features/ai_runtime/tool_calling/tool_loop.dart';
import '../../features/ai_runtime/tool_calling/tool_permission.dart';
import '../../features/ai_runtime/tool_calling/tool_permission_dialog.dart';
import '../../features/campus_data/storage/account_cache_namespace.dart';
import '../../models/ai_capabilities.dart';
import '../../models/ai_chat_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/ai_assistant_provider.dart';
import '../../providers/edu_provider.dart';
import '../../services/ai_assistant_service.dart';
import '../../widgets/ai/ai_empty_state.dart';
import '../../widgets/ai/ai_error_card.dart';
import '../../widgets/ai/ai_evidence_card.dart';
import '../../widgets/ai/ai_input_composer.dart';
import '../../widgets/ai/ai_message_card.dart';
import '../../widgets/ai/ai_quota_banner.dart';
import '../../widgets/ai/ai_typing_status.dart';
import '../../widgets/campus/campus_theme.dart';
import 'ai_model_settings_screen.dart';
import 'ai_feature_settings_screen.dart';
import 'graduation_checklist_screen.dart';
import 'personal_data_center_screen.dart';

class AiAssistantScreen extends StatefulWidget {
  final AiCapabilities capabilities;
  final AiAssistantService service;
  final Dio dio;

  const AiAssistantScreen({
    super.key,
    required this.capabilities,
    required this.service,
    required this.dio,
  });

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late final AiAssistantProvider _provider;
  final TextEditingController _inputController = TextEditingController();
  final List<AiChatMessage> _personalMessages = <AiChatMessage>[];
  final AIFeatureFlagStore _featureFlags = AIFeatureFlagStore();
  bool _personalMode = false;
  bool _personalSending = false;
  String? _personalError;
  List<SkillEvidence> _personalEvidence = const <SkillEvidence>[];
  ToolLoopCancellationToken? _toolCancellation;
  OpenAIToolCallingModel? _activeToolModel;
  ToolPermissionManager? _permissionManager;

  @override
  void initState() {
    super.initState();
    _provider = AiAssistantProvider(
      widget.service,
      initialCapabilities: widget.capabilities,
    );
    unawaited(_provider.initialize());
  }

  @override
  void dispose() {
    _toolCancellation?.cancel();
    unawaited(_activeToolModel?.cancel());
    _permissionManager?.clearSession();
    _inputController.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _submit(String message) {
    if (_personalMode) {
      unawaited(_submitPersonal(message));
      return;
    }
    unawaited(_submitPublic(message));
  }

  Future<void> _submitPublic(String message) async {
    if (!await _featureFlags.isEnabled(AIFeatureFlag.chat)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('校园 AI 问答当前已关闭')),
        );
      }
      return;
    }
    final result = _provider.submit(message);
    if (result == AiSubmitResult.accepted && mounted) _inputController.clear();
  }

  Future<void> _submitPersonal(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || _personalSending) return;
    final flags = await _featureFlags.readAll();
    if (!mounted) return;
    if (const <AIFeatureFlag>[
      AIFeatureFlag.personalGateway,
      AIFeatureFlag.personalSkills,
      AIFeatureFlag.toolCalling,
      AIFeatureFlag.customProvider,
    ].any((flag) => flags[flag] != true)) {
      setState(() => _personalError = '个人助手当前已由安全开关关闭');
      return;
    }
    final auth = context.read<AuthProvider>();
    final edu = context.read<EduProvider>();
    final appUserId = auth.user?.id.toString() ?? '';
    final sourceAccountId = edu.studentId.trim();
    if (appUserId.isEmpty || sourceAccountId.isEmpty) {
      setState(() => _personalError = '请先登录并完成教务绑定');
      return;
    }
    final now = DateTime.now();
    final requestId = now.microsecondsSinceEpoch.toString();
    setState(() {
      _personalSending = true;
      _personalError = null;
      _personalEvidence = const <SkillEvidence>[];
      _personalMessages.add(
        AiChatMessage(
          id: 'user-$requestId',
          requestId: requestId,
          role: AiMessageRole.user,
          content: message,
          status: AiMessageStatus.completed,
          createdAt: now,
        ),
      );
      _inputController.clear();
    });

    final gateway = PersonalDataGatewayFactory().create(
      PersonalAccountContext(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
      ),
    );
    try {
      final model = await OpenAIToolCallingModel.create(
        settingsStore: AIProviderSettingsStore(appUserId: appUserId),
      );
      if (!mounted) {
        await model.cancel();
        return;
      }
      _activeToolModel = model;
      final registry = buildStageSevenSkillRegistry(
        competitionSearchSource: DioCompetitionSearchSource(widget.dio),
        graduationRuleProvider: const _NoVerifiedRuleProvider(),
        competitionFitDataSource: _DioCompetitionFitDataSource(
          widget.dio,
          edu,
        ),
      );
      final cancellation = ToolLoopCancellationToken();
      _toolCancellation = cancellation;
      final permissionManager = _permissionManager ??=
          ToolPermissionManager(prompt: FlutterToolPermissionPrompt(context));
      final accountFingerprint = AccountCacheNamespace.fingerprint(appUserId);
      final loop = LocalToolLoop(
        registry: registry,
        executionContext: SkillExecutionContext(personalDataGateway: gateway),
        model: model,
        permissionManager: permissionManager,
        auditSink: LocalToolAuditStore(
          accountFingerprint: accountFingerprint,
        ),
        accountGeneration: () => Object.hash(
          auth.user?.id.toString(),
          edu.studentId,
        ),
        accountScope: accountFingerprint,
      );
      final tools = buildStageSixToolDefinitions().where((tool) {
        if (tool.id.startsWith('personal.academic.') &&
            flags[AIFeatureFlag.academicEngine] != true) {
          return false;
        }
        if (tool.id == GraduationReadinessSkill.skillId &&
            flags[AIFeatureFlag.graduationAssistant] != true) {
          return false;
        }
        return true;
      }).toList(growable: false);
      final outcome = await loop.run(
        userMessage: message,
        tools: tools,
        cancellationToken: cancellation,
      );
      if (!mounted) return;
      if (outcome.status == ToolLoopStatus.completed) {
        setState(() {
          _personalMessages.add(
            AiChatMessage(
              id: 'assistant-$requestId',
              requestId: requestId,
              role: AiMessageRole.assistant,
              content: outcome.answer,
              status: AiMessageStatus.completed,
              createdAt: DateTime.now(),
            ),
          );
          _personalEvidence = outcome.evidence;
        });
      } else {
        setState(() {
          _personalError = outcome.warnings.isEmpty
              ? _toolStatusMessage(outcome.status)
              : outcome.warnings.join('；');
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _personalError = error is Exception
              ? error.toString().replaceFirst('Exception: ', '')
              : '个人助手暂不可用';
        });
      }
    } finally {
      await gateway.close();
      if (mounted) {
        setState(() {
          _personalSending = false;
          _toolCancellation = null;
          _activeToolModel = null;
        });
      }
    }
  }

  String _toolStatusMessage(ToolLoopStatus status) => switch (status) {
        ToolLoopStatus.permissionDenied => '已取消个人数据授权',
        ToolLoopStatus.cancelled => '请求已取消',
        ToolLoopStatus.rejected => '请求未通过本地安全校验',
        ToolLoopStatus.failed => '个人助手执行失败',
        ToolLoopStatus.completed => '',
      };

  Future<void> _cancelPersonal() async {
    _toolCancellation?.cancel();
    await _activeToolModel?.cancel();
  }

  Future<void> _showConversations() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer<AiAssistantProvider>(
        builder: (_, provider, __) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.62,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('历史会话',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                        IconButton(
                          tooltip: '新建会话',
                          onPressed: () {
                            provider.startNewConversation();
                            Navigator.pop(sheetContext);
                          },
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: provider.loadingConversations
                        ? const Center(child: CircularProgressIndicator())
                        : provider.conversations.isEmpty
                            ? const Center(child: Text('暂无历史会话'))
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 20),
                                itemCount: provider.conversations.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, index) {
                                  final conversation =
                                      provider.conversations[index];
                                  final selected = conversation.id ==
                                      provider.conversationId;
                                  return ListTile(
                                    selected: selected,
                                    leading: const Icon(Icons.forum_outlined),
                                    title: Text(
                                      conversation.title.isEmpty
                                          ? '新会话'
                                          : conversation.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      tooltip: '删除会话',
                                      icon: const Icon(
                                          Icons.delete_outline_rounded),
                                      onPressed: () async {
                                        final confirmed =
                                            await showDialog<bool>(
                                          context: sheetContext,
                                          builder: (dialogContext) =>
                                              AlertDialog(
                                            title: const Text('删除会话？'),
                                            content:
                                                const Text('删除后无法恢复其中的问答记录。'),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogContext, false),
                                                  child: const Text('取消')),
                                              FilledButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          dialogContext, true),
                                                  child: const Text('删除')),
                                            ],
                                          ),
                                        );
                                        if (confirmed == true) {
                                          await provider.deleteConversation(
                                              conversation.id);
                                        }
                                      },
                                    ),
                                    onTap: () {
                                      provider
                                          .openConversation(conversation.id);
                                      Navigator.pop(sheetContext);
                                    },
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPersonalBody() {
    if (_personalMessages.isEmpty) {
      const actions = <(IconData, String, String)>[
        (Icons.today_outlined, '今天安排', '我今天有什么课？'),
        (Icons.school_outlined, '我的学业', '计算我的 GPA 和学分情况。'),
        (Icons.emoji_events_outlined, '竞赛建议', '最近有什么适合我的竞赛？'),
        (Icons.fitness_center_outlined, '运动计划', '帮我安排本周运动时间。'),
        (Icons.fact_check_outlined, '毕业清单', '我的毕业要求还有哪些未完成？'),
        (Icons.dashboard_outlined, '二课概览', '我还差多少二课分？'),
      ];
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 84,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: actions.length,
        itemBuilder: (context, index) {
          final action = actions[index];
          return OutlinedButton.icon(
            onPressed: () {
              _inputController.text = action.$3;
              _inputController.selection = TextSelection.collapsed(
                offset: action.$3.length,
              );
            },
            icon: Icon(action.$1),
            label: Text(action.$2),
          );
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      children: [
        for (final message in _personalMessages)
          AiMessageCard(message: message),
        if (_personalEvidence.isNotEmpty)
          AiEvidenceCard(evidence: _personalEvidence),
        if (_personalSending) const AiTypingStatus(status: '正在本地校验并执行已授权能力'),
        if (_personalError != null)
          AiErrorCard(
            message: _personalError!,
            actionLabel: '关闭',
            onAction: () => setState(() => _personalError = null),
          ),
      ],
    );
  }

  Future<void> _openAiSetting(String value) async {
    final auth = context.read<AuthProvider>();
    final edu = context.read<EduProvider>();
    final appUserId = auth.user?.id.toString() ?? '';
    if (appUserId.isEmpty) return;
    final Widget page = switch (value) {
      'model' => AIModelSettingsScreen(appUserId: appUserId),
      'flags' => const AIFeatureSettingsScreen(),
      'data' => PersonalDataCenterScreen(
          appUserId: appUserId,
          sourceAccountId: edu.studentId,
        ),
      _ => GraduationChecklistScreen(
          readiness: GraduationReadiness(
            policyId: 'unknown',
            items: const <GraduationRequirementItem>[
              GraduationRequirementItem(
                id: 'policy',
                label: '培养方案',
                state: RequirementState.blocked,
                summary: '请先通过个人助手加载已审核的适用培养方案',
              ),
            ],
            warnings: const <String>['当前没有可执行的已审核政策规则'],
          ),
        ),
    };
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _provider,
      child: Consumer<AiAssistantProvider>(
        builder: (context, provider, _) {
          final capabilities = provider.capabilities ?? widget.capabilities;
          final quota = provider.quota ?? capabilities.quota;
          return Scaffold(
            backgroundColor: CampusTheme.bg,
            appBar: AppBar(
              backgroundColor: CampusTheme.bg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              titleSpacing: 0,
              title: Row(
                children: [
                  const Text(
                    '沈理 AI',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: CampusTheme.primaryLight,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Text(
                      '内测',
                      style: TextStyle(
                        color: CampusTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                if (!_personalMode)
                  IconButton(
                    tooltip: '历史会话',
                    onPressed: _showConversations,
                    icon: const Icon(Icons.history_rounded),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'AI 设置',
                  icon: const Icon(Icons.settings_outlined),
                  onSelected: _openAiSetting,
                  itemBuilder: (_) => const <PopupMenuEntry<String>>[
                    PopupMenuItem(value: 'model', child: Text('模型设置')),
                    PopupMenuItem(value: 'data', child: Text('个人数据保险箱')),
                    PopupMenuItem(value: 'graduation', child: Text('毕业清单')),
                    PopupMenuItem(value: 'flags', child: Text('功能开关')),
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      segments: const <ButtonSegment<bool>>[
                        ButtonSegment<bool>(
                          value: false,
                          icon: Icon(Icons.public_outlined),
                          label: Text('校园问答'),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          icon: Icon(Icons.person_outline),
                          label: Text('个人助手'),
                        ),
                      ],
                      selected: <bool>{_personalMode},
                      onSelectionChanged: (selection) {
                        setState(() => _personalMode = selection.single);
                      },
                    ),
                  ),
                ),
                if (!_personalMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: AiQuotaBanner(
                      quota: quota,
                      maxCharacters: capabilities.maxMessageChars,
                    ),
                  ),
                Expanded(
                  child: _personalMode
                      ? _buildPersonalBody()
                      : provider.messages.isEmpty
                          ? ListView(
                              children: [
                                AiEmptyState(
                                  chatEnabled: capabilities.chatEnabled,
                                  quickPrompts: provider.quickPrompts,
                                  onPromptSelected: (prompt) {
                                    _inputController.text = prompt;
                                    _inputController.selection =
                                        TextSelection.collapsed(
                                      offset: prompt.length,
                                    );
                                  },
                                ),
                                if (provider.error != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    child: AiErrorCard(
                                      message: provider.error!,
                                      actionLabel:
                                          provider.canRetry ? '重试' : '重新连接',
                                      onAction: provider.canRetry
                                          ? provider.retryLast
                                          : provider.reconnect,
                                    ),
                                  ),
                              ],
                            )
                          : ListView(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 10, 16, 18),
                              children: [
                                for (final message in provider.messages)
                                  AiMessageCard(message: message),
                                if (provider.isRunning)
                                  AiTypingStatus(
                                    status: provider.friendlyRunStatus,
                                  ),
                                if (provider.error != null)
                                  AiErrorCard(
                                    message: provider.error!,
                                    actionLabel:
                                        provider.canRetry ? '重试' : '重新连接',
                                    onAction: provider.canRetry
                                        ? provider.retryLast
                                        : provider.reconnect,
                                  ),
                              ],
                            ),
                ),
                AiInputComposer(
                  controller: _inputController,
                  maxCharacters: capabilities.maxMessageChars,
                  enabled: _personalMode
                      ? !_personalSending
                      : capabilities.chatEnabled && quota.remaining > 0,
                  running:
                      _personalMode ? _personalSending : provider.isRunning,
                  onSend: _submit,
                  onCancel: _personalMode ? _cancelPersonal : provider.cancel,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoVerifiedRuleProvider implements GraduationRuleProvider {
  const _NoVerifiedRuleProvider();

  @override
  Future<CurriculumRulePackage?> currentRules() async => null;
}

class _DioCompetitionFitDataSource implements CompetitionFitDataSource {
  _DioCompetitionFitDataSource(this._dio, this._edu);

  final Dio _dio;
  final EduProvider _edu;

  @override
  Future<List<CompetitionCandidate>> candidates() async {
    final response = await _dio.get<dynamic>(
      '/competitions/events',
      queryParameters: const <String, dynamic>{'page': 1, 'page_size': 20},
    );
    if (response.data is! Map) return const <CompetitionCandidate>[];
    final items = (response.data as Map)['items'];
    if (items is! List) return const <CompetitionCandidate>[];
    return items.whereType<Map>().map((raw) {
      final map = Map<String, dynamic>.from(raw);
      return CompetitionCandidate(
        id: map['id']?.toString() ?? '',
        title: map['title']?.toString() ?? '',
        eligibleGrades: _strings(
          map['eligible_grades'] ?? map['eligible_entry_years'],
        ),
        eligibleColleges: _strings(map['eligible_colleges']),
        eligibleMajors: _strings(map['eligible_majors']),
        schoolRecognitionStatus:
            map['school_recognition_status']?.toString() ?? '',
        schoolRecognitionGrade:
            map['school_recognition_grade']?.toString() ?? '',
        importanceScore: (map['importance_score'] as num?)?.toInt() ?? 0,
        manualRating: (map['manual_rating'] as num?)?.toDouble(),
        evidenceStatus: map['evidence_status']?.toString() ?? '',
        strongRecommendationReady: map['strong_recommendation_ready'] == true,
        registrationOpen: map['registration_open'] == true,
        tags: _strings(map['tags']),
      );
    }).toList(growable: false);
  }

  @override
  Future<StudentCompetitionProfile> currentProfile() async {
    return StudentCompetitionProfile(
      grade: _edu.grade,
      college: _edu.college,
      major: _edu.major,
    );
  }

  static List<String> _strings(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }
}
