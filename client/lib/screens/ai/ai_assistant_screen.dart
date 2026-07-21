import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import '../../features/ai_runtime/ai_feature_flags.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/personal_ai_runtime_limits.dart';
import '../../features/ai_runtime/deterministic/competition_fit_engine.dart';
import '../../features/ai_runtime/deterministic/graduation_requirement_engine.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_account_context.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import '../../features/ai_runtime/personal_data/gateway/unavailable_personal_data_gateway.dart';
import '../../features/ai_runtime/personal_session/personal_conversation_store.dart';
import '../../features/ai_runtime/personal_session/personal_session_epoch.dart';
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
import '../../widgets/app_action_popup_menu.dart';
import '../../widgets/app_page_app_bar.dart';
import '../../widgets/campus/campus_theme.dart';
import 'ai_model_settings_screen.dart';
import 'ai_feature_settings_screen.dart';
import 'graduation_checklist_screen.dart';
import 'personal_data_center_screen.dart';
import '../../widgets/ai/ai_history_sheet.dart';
import '../../widgets/ai/ai_app_bar_title.dart';
import '../../widgets/ai/ai_mode_switch.dart';

class AiAssistantScreen extends StatefulWidget {
  final AiCapabilities capabilities;
  final AiAssistantService service;
  final Dio dio;
  final PersonalConversationStore Function(String accountKey)?
      personalConversationStoreFactory;

  const AiAssistantScreen({
    super.key,
    required this.capabilities,
    required this.service,
    required this.dio,
    this.personalConversationStoreFactory,
  });

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late final AiAssistantProvider _provider;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final List<AiChatMessage> _personalMessages = <AiChatMessage>[];
  final List<PersonalConversationEntry> _personalConversationEntries =
      <PersonalConversationEntry>[];
  final AIFeatureFlagStore _featureFlags = AIFeatureFlagStore();
  bool _personalMode = false;
  bool _personalSending = false;
  String? _personalError;
  bool _personalNeedsModelConfiguration = false;
  List<SkillEvidence> _personalEvidence = const <SkillEvidence>[];
  ToolLoopCancellationToken? _toolCancellation;
  OpenAIToolCallingModel? _activeToolModel;
  ToolPermissionManager? _permissionManager;
  String? _permissionAccountKey;
  PersonalConversationStore? _personalConversationStore;
  String? _loadedConversationAccountKey;
  bool _personalHistoryLoading = false;
  final PersonalSessionEpoch _personalSessionEpoch = PersonalSessionEpoch();
  AuthProvider? _authProvider;
  EduProvider? _eduProvider;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    final edu = context.read<EduProvider>();
    if (!identical(_authProvider, auth)) {
      _authProvider?.removeListener(_handleAccountContextChanged);
      _authProvider = auth..addListener(_handleAccountContextChanged);
    }
    if (!identical(_eduProvider, edu)) {
      _eduProvider?.removeListener(_handleAccountContextChanged);
      _eduProvider = edu..addListener(_handleAccountContextChanged);
    }
    _synchronizePersonalAccount();
  }

  @override
  void dispose() {
    _authProvider?.removeListener(_handleAccountContextChanged);
    _eduProvider?.removeListener(_handleAccountContextChanged);
    _toolCancellation?.cancel();
    unawaited(_activeToolModel?.cancel());
    _inputFocusNode.dispose();
    _inputController.dispose();
    _provider.dispose();
    super.dispose();
  }

  String _currentPersonalAccountKey() {
    final appUserId = _authProvider?.user?.id.toString() ?? '';
    final sourceAccountId = _eduProvider?.studentId.trim() ?? '';
    return '$appUserId::$sourceAccountId';
  }

  void _handleAccountContextChanged() {
    if (!mounted) return;
    _synchronizePersonalAccount();
  }

  void _synchronizePersonalAccount() {
    final changed = _personalSessionEpoch.synchronizeAccount(
      _currentPersonalAccountKey(),
    );
    if (changed) _resetPersonalSessionForAccountChange();
    _ensurePersonalHistoryLoaded();
  }

  void _resetPersonalSessionForAccountChange() {
    final cancellation = _toolCancellation;
    final model = _activeToolModel;
    _toolCancellation = null;
    _activeToolModel = null;
    cancellation?.cancel();
    unawaited(model?.cancel());
    _clearPersonalPermissions();
    setState(() {
      _personalMessages.clear();
      _personalConversationEntries.clear();
      _personalEvidence = const <SkillEvidence>[];
      _personalError = null;
      _personalNeedsModelConfiguration = false;
      _personalSending = false;
      _personalHistoryLoading = false;
      _inputController.clear();
    });
    _personalConversationStore = null;
    _loadedConversationAccountKey = null;
  }

  bool _isCurrentPersonalRequest(PersonalRequestEpoch request) =>
      mounted && _personalSessionEpoch.isCurrent(request);

  ToolPermissionManager _permissionManagerFor(String accountKey) {
    if (_permissionManager == null || _permissionAccountKey != accountKey) {
      _permissionManager?.clearSession();
      _permissionAccountKey = accountKey;
      _permissionManager = ToolPermissionManager(
        prompt: FlutterToolPermissionPrompt(context),
        accountKey: accountKey,
      );
    }
    return _permissionManager!;
  }

  void _clearPersonalPermissions() {
    _permissionManager?.clearSession();
    _permissionManager = null;
    _permissionAccountKey = null;
  }

  void _ensurePersonalHistoryLoaded() {
    final appUserId = _authProvider?.user?.id.toString() ?? '';
    final accountKey = _personalSessionEpoch.accountKey ?? '';
    if (appUserId.isEmpty ||
        accountKey.isEmpty ||
        _loadedConversationAccountKey == accountKey) {
      return;
    }
    final requestEpoch = _personalSessionEpoch.capture();
    final store = widget.personalConversationStoreFactory?.call(accountKey) ??
        PersonalConversationStore(accountKey: accountKey);
    _personalConversationStore = store;
    _loadedConversationAccountKey = accountKey;
    _personalHistoryLoading = true;
    unawaited(_loadPersonalHistory(store, requestEpoch));
  }

  Future<void> _loadPersonalHistory(
    PersonalConversationStore store,
    PersonalRequestEpoch requestEpoch,
  ) async {
    final entries = await store.read();
    if (!_isCurrentPersonalRequest(requestEpoch) ||
        !identical(_personalConversationStore, store)) {
      return;
    }
    final assistantEntries = entries
        .where((item) => item.message.role == AiMessageRole.assistant)
        .toList(growable: false);
    setState(() {
      _personalHistoryLoading = false;
      _personalConversationEntries
        ..clear()
        ..addAll(entries);
      _personalMessages
        ..clear()
        ..addAll(entries.map((item) => item.message));
      _personalEvidence = assistantEntries.isEmpty
          ? const <SkillEvidence>[]
          : assistantEntries.last.evidence;
    });
  }

  Future<void> _persistPersonalHistory() async {
    final store = _personalConversationStore;
    if (store == null) return;
    final entries = List<PersonalConversationEntry>.of(
      _personalConversationEntries,
    );
    try {
      await store.replace(entries);
    } catch (_) {
      // 会话仍保留在当前页面内存中，安全存储失败不影响本轮回答。
    }
  }

  void _trimPersonalConversation() {
    var characters = _personalConversationEntries.fold<int>(
      0,
      (sum, item) => sum + item.message.content.length,
    );
    while (_personalConversationEntries.length >
            PersonalConversationStore.maximumMessages ||
        (_personalConversationEntries.isNotEmpty &&
            characters > PersonalConversationStore.maximumCharacters)) {
      final removed = _personalConversationEntries.removeAt(0);
      characters -= removed.message.content.length;
      _personalMessages.removeWhere((item) => item.id == removed.message.id);
    }
  }

  Future<void> _clearPersonalConversation() async {
    final cancellation = _toolCancellation;
    final model = _activeToolModel;
    final store = _personalConversationStore;
    _personalSessionEpoch.invalidate();
    _toolCancellation = null;
    _activeToolModel = null;
    cancellation?.cancel();
    unawaited(model?.cancel());
    _clearPersonalPermissions();
    setState(() {
      _personalMessages.clear();
      _personalConversationEntries.clear();
      _personalEvidence = const <SkillEvidence>[];
      _personalError = null;
      _personalNeedsModelConfiguration = false;
      _personalSending = false;
      _inputController.clear();
    });
    if (store != null) {
      try {
        await store.clear();
      } catch (_) {
        if (mounted) setState(() => _personalError = '清空个人会话失败，请稍后重试');
      }
    }
  }

  List<ToolConversationMessage> _personalConversationHistory() =>
      _personalConversationEntries
          .where((item) => item.message.status == AiMessageStatus.completed)
          .map(
            (item) => ToolConversationMessage(
              role: item.message.role == AiMessageRole.user
                  ? ToolMessageRole.user
                  : ToolMessageRole.assistant,
              content: item.message.content,
            ),
          )
          .toList(growable: false);

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
    if (message.isEmpty || _personalSending || _personalHistoryLoading) return;
    if (!PersonalAIRuntimeLimits.acceptsInput(message)) {
      setState(() {
        _personalError =
            '个人助手单条消息不能超过 ${PersonalAIRuntimeLimits.maximumInputCharacters} 个字符';
      });
      return;
    }
    final requestEpoch = _personalSessionEpoch.capture();
    final flags = await _featureFlags.readAll();
    if (!_isCurrentPersonalRequest(requestEpoch)) return;
    if (const <AIFeatureFlag>[
      AIFeatureFlag.personalGateway,
      AIFeatureFlag.personalSkills,
      AIFeatureFlag.toolCalling,
      AIFeatureFlag.customProvider,
    ].any((flag) => flags[flag] != true)) {
      setState(() => _personalError = '个人助手当前已由安全开关关闭');
      return;
    }
    final auth = _authProvider!;
    final edu = _eduProvider!;
    final appUserId = auth.user?.id.toString() ?? '';
    final sourceAccountId = edu.studentId.trim();
    if (appUserId.isEmpty) {
      setState(() => _personalError = '请先登录 App 账号');
      return;
    }
    OpenAIToolCallingModel model;
    try {
      model = await OpenAIToolCallingModel.create(
        settingsStore: AIProviderSettingsStore(appUserId: appUserId),
      );
    } catch (error) {
      if (_isCurrentPersonalRequest(requestEpoch)) {
        setState(() {
          _personalError = error.toString();
          _personalNeedsModelConfiguration = true;
        });
      }
      return;
    }
    if (!_isCurrentPersonalRequest(requestEpoch)) {
      await model.cancel();
      return;
    }
    final now = DateTime.now();
    final requestId = now.microsecondsSinceEpoch.toString();
    if (!_personalSessionEpoch.activate(requestEpoch, requestId)) {
      await model.cancel();
      return;
    }
    _activeToolModel = model;
    final conversationHistory = _personalConversationHistory();
    final userMessage = AiChatMessage(
      id: 'user-$requestId',
      requestId: requestId,
      role: AiMessageRole.user,
      content: message,
      status: AiMessageStatus.completed,
      createdAt: now,
    );
    setState(() {
      _personalSending = true;
      _personalError = null;
      _personalNeedsModelConfiguration = false;
      _personalEvidence = const <SkillEvidence>[];
      _personalMessages.add(userMessage);
      _personalConversationEntries.add(
        PersonalConversationEntry(message: userMessage),
      );
      _trimPersonalConversation();
      _inputController.clear();
    });
    await _persistPersonalHistory();

    final hasEduAccount = sourceAccountId.isNotEmpty;
    final PersonalDataGateway gateway = hasEduAccount
        ? PersonalDataGatewayFactory().create(
            PersonalAccountContext(
              appUserId: appUserId,
              sourceAccountId: sourceAccountId,
            ),
            refreshAcademicData: () async {
              final result = await edu.syncAllGrades();
              return result.success ? null : result.errorMessage ?? '自动同步成绩失败';
            },
          )
        : const UnavailablePersonalDataGateway();
    if (!mounted || !_personalSessionEpoch.owns(requestEpoch, requestId)) {
      await gateway.close();
      await model.cancel();
      return;
    }
    final cancellation = ToolLoopCancellationToken();
    _toolCancellation = cancellation;
    try {
      final registry = buildStageSevenSkillRegistry(
        competitionSearchSource: DioCompetitionSearchSource(widget.dio),
        graduationRuleProvider: const _NoVerifiedRuleProvider(),
        competitionFitDataSource: _DioCompetitionFitDataSource(
          widget.dio,
          edu,
        ),
      );
      final loop = LocalToolLoop(
        registry: registry,
        executionContext: SkillExecutionContext(personalDataGateway: gateway),
        model: model,
        permissionManager: _permissionManagerFor(requestEpoch.accountKey),
        auditSink: LocalToolAuditStore(
          accountFingerprint: AccountCacheNamespace.fingerprint(appUserId),
        ),
        accountGeneration: () => _personalSessionEpoch.generation,
        skillTimeout: const Duration(seconds: 90),
      );
      final tools = buildStageSixToolDefinitions().where((tool) {
        if (!hasEduAccount &&
            (registry.requiredDataTypesFor(tool.id)?.isNotEmpty ?? false)) {
          return false;
        }
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
      final unavailableToolReasons = <String, String>{
        if (!hasEduAccount)
          for (final tool in buildStageSixToolDefinitions())
            if (registry.requiredDataTypesFor(tool.id)?.isNotEmpty ?? false)
              tool.id: '需要绑定教务后才能读取年级、学院、专业或个人校园数据',
      };
      final outcome = await loop.run(
        userMessage: message,
        tools: tools,
        conversationHistory: conversationHistory,
        unavailableToolReasons: unavailableToolReasons,
        cancellationToken: cancellation,
      );
      if (!_personalSessionEpoch.owns(requestEpoch, requestId)) return;
      if (outcome.status == ToolLoopStatus.completed) {
        final assistantMessage = AiChatMessage(
          id: 'assistant-$requestId',
          requestId: requestId,
          role: AiMessageRole.assistant,
          content: outcome.answer,
          status: AiMessageStatus.completed,
          createdAt: DateTime.now(),
        );
        setState(() {
          _personalMessages.add(assistantMessage);
          _personalConversationEntries.add(
            PersonalConversationEntry(
              message: assistantMessage,
              evidence: outcome.evidence,
            ),
          );
          _trimPersonalConversation();
          _personalEvidence = outcome.evidence;
        });
        await _persistPersonalHistory();
      } else {
        setState(() {
          _personalError = outcome.warnings.isEmpty
              ? _toolStatusMessage(outcome.status)
              : outcome.warnings.join('；');
        });
      }
    } catch (error) {
      if (_personalSessionEpoch.owns(requestEpoch, requestId)) {
        setState(() {
          _personalError = error is Exception
              ? error.toString().replaceFirst('Exception: ', '')
              : '个人助手暂不可用';
          _personalNeedsModelConfiguration = false;
        });
      }
    } finally {
      await gateway.close();
      if (_personalSessionEpoch.release(requestEpoch, requestId) && mounted) {
        setState(() {
          _personalSending = false;
          if (identical(_toolCancellation, cancellation)) {
            _toolCancellation = null;
          }
          if (identical(_activeToolModel, model)) {
            _activeToolModel = null;
          }
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

  Future<void> _checkPersonalConfiguration() async {
    final requestEpoch = _personalSessionEpoch.capture();
    final auth = _authProvider!;
    final appUserId = auth.user?.id.toString() ?? '';
    if (appUserId.isEmpty) {
      if (mounted && _personalMode) {
        setState(() {
          _personalError = '请先登录 App 账号';
          _personalNeedsModelConfiguration = false;
        });
      }
      return;
    }
    try {
      final model = await OpenAIToolCallingModel.create(
        settingsStore: AIProviderSettingsStore(appUserId: appUserId),
      );
      await model.cancel();
      if (_isCurrentPersonalRequest(requestEpoch) &&
          _personalMode &&
          _personalNeedsModelConfiguration) {
        setState(() {
          _personalError = null;
          _personalNeedsModelConfiguration = false;
        });
      }
    } catch (error) {
      if (_isCurrentPersonalRequest(requestEpoch) && _personalMode) {
        setState(() {
          _personalError = error.toString();
          _personalNeedsModelConfiguration = true;
        });
      }
    }
  }

  Future<void> _showConversations() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (sheetContext) =>
          ChangeNotifierProvider<AiAssistantProvider>.value(
        value: _provider,
        child: AiHistorySheet(
          onFocusRequest: () {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _inputFocusNode.requestFocus();
            });
          },
        ),
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
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        children: [
          if (_personalError != null)
            AiErrorCard(
              message: _personalError!,
              actionLabel: _personalNeedsModelConfiguration ? '去配置' : '关闭',
              onAction: _personalNeedsModelConfiguration
                  ? () => _openAiSetting('model')
                  : () => setState(() => _personalError = null),
            ),
          if (_personalError != null) const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
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
          ),
        ],
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
            actionLabel: _personalNeedsModelConfiguration ? '去配置' : '关闭',
            onAction: _personalNeedsModelConfiguration
                ? () => _openAiSetting('model')
                : () => setState(() => _personalError = null),
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
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => page),
    );
    if (saved == true && value == 'model' && mounted) {
      _clearPersonalPermissions();
      setState(() {
        _personalError = null;
        _personalNeedsModelConfiguration = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('个人助手模型已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _provider,
      child: Consumer<AiAssistantProvider>(
        builder: (context, provider, _) {
          final capabilities = provider.capabilities ?? widget.capabilities;
          final quota = provider.quota ?? capabilities.quota;
          final maxInputCharacters = _personalMode
              ? PersonalAIRuntimeLimits.maximumInputCharacters
              : capabilities.maxMessageChars;
          return Scaffold(
            backgroundColor: CampusTheme.pageBackground(context),
            appBar: AppPageAppBar(
              title: const AiAppBarTitle(),
              actions: [
                if (!_personalMode)
                  IconButton(
                    tooltip: '历史会话',
                    onPressed: _showConversations,
                    icon: const Icon(Icons.history_rounded),
                  ),
                if (_personalMode && _personalMessages.isNotEmpty)
                  IconButton(
                    tooltip: '新建个人会话',
                    onPressed: _clearPersonalConversation,
                    icon: const Icon(Icons.note_add_outlined),
                  ),
                AppActionPopupMenu(
                  icon: const Icon(Icons.settings_outlined),
                  entries: const <Object>[
                    AppPopupAction(
                      value: 'model',
                      label: '模型设置',
                      icon: Icons.tune_rounded,
                    ),
                    AppPopupAction(
                      value: 'data',
                      label: '个人数据保险箱',
                      icon: Icons.shield_outlined,
                    ),
                    AppPopupAction(
                      value: 'graduation',
                      label: '毕业清单',
                      icon: Icons.fact_check_outlined,
                    ),
                    AppPopupAction(
                      value: 'flags',
                      label: '功能开关',
                      icon: Icons.toggle_on_outlined,
                    ),
                  ],
                  onSelected: _openAiSetting,
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: Column(
              children: [
                AiModeSwitch(
                  isPersonalMode: _personalMode,
                  onModeChanged: (selected) {
                    if (!selected) _clearPersonalPermissions();
                    setState(() {
                      _personalMode = selected;
                      if (selected) {
                        _personalError = null;
                        _personalNeedsModelConfiguration = false;
                      }
                    });
                    if (selected) unawaited(_checkPersonalConfiguration());
                  },
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
                  focusNode: _inputFocusNode,
                  maxCharacters: maxInputCharacters,
                  enabled: _personalMode
                      ? !_personalSending && !_personalHistoryLoading
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
