import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import '../../config/beta_release_policy.dart';
import '../../features/ai_runtime/ai_feature_flags.dart';
import '../../features/ai_device_bridge/device_tool_worker.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../features/ai_runtime/personal_ai_runtime_limits.dart';
import '../../features/ai_runtime/deterministic/graduation_requirement_engine.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_account_context.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_data_gateway.dart';
import '../../features/ai_runtime/personal_data/gateway/personal_data_gateway_impl.dart';
import '../../features/ai_runtime/personal_data/gateway/unavailable_personal_data_gateway.dart';
import '../../features/ai_runtime/personal_session/personal_conversation_store.dart';
import '../../features/ai_runtime/personal_session/personal_session_epoch.dart';
import '../../features/ai_runtime/skills/competition_search_skill.dart';
import '../../features/ai_runtime/skills/competition_advisor_skills.dart';
import '../../features/ai_runtime/skills/competition_plan_action_skill.dart';
import '../../features/ai_runtime/skills/calendar_action_skill.dart';
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
import '../../models/ai_run_event.dart';
import '../../models/competition_action_draft.dart';
import '../../models/agent_context.dart';
import '../../models/user_calendar.dart';
import '../../platform/contracts/reminder_notification_client.dart';
import '../../providers/auth_provider.dart';
import '../../providers/ai_assistant_provider.dart';
import '../../providers/edu_provider.dart';
import '../../services/ai_assistant_service.dart';
import '../../services/ai_personal_data_permission_service.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/ai/ai_empty_state.dart';
import '../../widgets/ai/ai_personal_empty_state.dart';
import '../../widgets/ai/ai_error_card.dart';
import '../../widgets/ai/ai_evidence_card.dart';
import '../../widgets/ai/ai_input_composer.dart';
import '../../widgets/ai/ai_message_card.dart';
import '../../widgets/ai/ai_quota_banner.dart';
import '../../widgets/ai/ai_typing_status.dart';
import '../../widgets/app_action_popup_menu.dart';
import '../../widgets/app_page_app_bar.dart';
import 'ai_model_settings_screen.dart';
import 'ai_feature_settings_screen.dart';
import 'graduation_checklist_screen.dart';
import 'personal_data_center_screen.dart';
import '../erke_score_screen.dart';
import '../../widgets/ai/ai_history_sheet.dart';
import '../../widgets/ai/ai_app_bar_title.dart';
import '../../widgets/ai/ai_mode_switch.dart';
import '../../widgets/ai/ai_agent_execution_card.dart';
import '../../widgets/ai/ai_agent_permission_card.dart';
import '../../widgets/ai/ai_agent_permission_sheet.dart';
import '../../widgets/ai/admin_ai_control_sheet.dart';
import '../../widgets/campus/campus_theme.dart';
import '../competition/competition_center_screen.dart';
import '../account_security_screen.dart';

enum _ConsentChoice { denied, once, always }

class AiAssistantScreen extends StatefulWidget {
  final AiCapabilities capabilities;
  final AiAssistantService service;
  final Dio dio;
  final bool initialPersonalMode;
  final String? initialPrompt;
  final AgentLaunchContext? launchContext;
  final PersonalConversationStore Function(String accountKey)?
      personalConversationStoreFactory;

  const AiAssistantScreen({
    super.key,
    required this.capabilities,
    required this.service,
    required this.dio,
    this.initialPersonalMode = false,
    this.initialPrompt,
    this.launchContext,
    this.personalConversationStoreFactory,
  });

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late final AiAssistantProvider _provider;
  late final AiPersonalDataPermissionService _permissionService;
  final FocusNode _inputFocusNode = FocusNode();
  final TextEditingController _inputController = TextEditingController();

  String? _lastBootstrapAuthKey;
  bool _consentDialogVisible = false;
  String _lastConsentDialogKey = '';
  bool _agentTrusted = false;
  bool _agentPermissionLoaded = false;
  AgentPermissionLoadState _agentPermissionState =
      AgentPermissionLoadState.loading;
  DeviceBridgeStatus _bridgeStatus = DeviceToolBridge.status;

  final List<AiChatMessage> _personalMessages = <AiChatMessage>[];
  final List<PersonalConversationEntry> _personalConversationEntries =
      <PersonalConversationEntry>[];
  final AIFeatureFlagStore _featureFlags = AIFeatureFlagStore();
  late bool _personalMode;
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
    _personalMode = widget.initialPersonalMode;
    _provider = AiAssistantProvider(
      widget.service,
      initialCapabilities: widget.capabilities,
      deviceToolSync: DeviceToolBridge.syncPending,
      launchContext: widget.launchContext,
    );
    _permissionService = AiPersonalDataPermissionService(widget.dio);
    _provider.addListener(_handleRunConsentRequired);
    DeviceToolBridge.statusNotifier.addListener(_handleBridgeStatusChanged);
    final initialPrompt = widget.initialPrompt?.trim() ?? '';
    if (initialPrompt.isNotEmpty) {
      _inputController.value = TextEditingValue(
        text: initialPrompt,
        selection: TextSelection.collapsed(offset: initialPrompt.length),
      );
    }
    unawaited(_loadAgentPermissionMode());
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
    _synchronizeServerAccount();
  }

  @override
  void dispose() {
    _authProvider?.removeListener(_handleAccountContextChanged);
    _eduProvider?.removeListener(_handleAccountContextChanged);
    DeviceToolBridge.statusNotifier.removeListener(_handleBridgeStatusChanged);
    _toolCancellation?.cancel();
    unawaited(_activeToolModel?.cancel());
    _inputFocusNode.dispose();
    _inputController.dispose();
    _provider.removeListener(_handleRunConsentRequired);
    _provider.dispose();
    super.dispose();
  }

  void _handleBridgeStatusChanged() {
    if (!mounted) return;
    setState(() => _bridgeStatus = DeviceToolBridge.status);
  }

  Future<void> _retryDeviceBridge() async {
    try {
      await DeviceToolBridge.syncPending();
      if (mounted && DeviceToolBridge.status == DeviceBridgeStatus.connected) {
        AppFeedback.success('设备桥接已恢复', context: context);
      }
    } catch (_) {
      if (mounted) {
        AppFeedback.error('设备桥接仍不可用，请检查网络后重试', context: context);
      }
    }
  }

  void _handleRunConsentRequired() {
    final consent = _provider.pendingConsent;
    if (!mounted ||
        _personalMode ||
        !_agentPermissionLoaded ||
        consent == null ||
        consent.consentScope.isEmpty ||
        _consentDialogVisible) {
      return;
    }
    if (_agentTrusted) {
      unawaited(_autoApproveTrustedConsent(consent));
      return;
    }
    if (consent.consentScope !=
        AiPersonalDataPermissionScope.externalModelAnalysis.wireValue) {
      return;
    }
    final key = '${consent.runId}:${consent.seq}:${consent.consentScope}';
    if (key == _lastConsentDialogKey) return;
    _lastConsentDialogKey = key;
    _consentDialogVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _consentDialogVisible = false;
        return;
      }
      final dialogTheme = CampusTheme.withBrandAccent(Theme.of(context));
      final isDeviceConsent = consent.consentScope == 'ai_device_cache_access';
      final requestedData = consent.datasets
          .map(
            (dataset) => switch (dataset) {
              'grades' || 'academic' => '成绩摘要',
              'schedule' => '课表摘要',
              'erke' => '二课摘要',
              _ => '相关校园数据',
            },
          )
          .toSet()
          .join('、');
      final choice = await showDialog<_ConsentChoice>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Theme(
          data: dialogTheme,
          child: AlertDialog(
            title: Text(
              isDeviceConsent
                  ? '校园 Agent 想在你的设备上执行一次操作'
                  : consent.consentScope == 'ai_external_model_analysis'
                      ? '允许外部模型辅助分析？'
                      : '允许本次读取个人数据？',
            ),
            content: Text(
              isDeviceConsent
                  ? '为了回答当前问题，Agent 会检查数据新鲜度，必要时刷新并读取${requestedData.isEmpty ? '相关校园数据' : requestedData}，然后只回传本次问题所需的最小化摘要。\n\n不会读取密码、Cookie、Token 或设备标识。此选择只对当前请求生效，不会修改长期设置。'
                  : consent.consentScope == 'ai_external_model_analysis'
                      ? '本次分析会把经过最小化和去身份处理的课程成绩、学分、专业年级或课表时间发送给统一 AI 模型服务。\n\n不会发送姓名、学号、密码、Cookie、Token 或设备标识。'
                      : '校园 Agent 需要读取本次分析所需的最小化个人数据。此选择只对当前请求生效，不会修改个人数据保险箱中的长期设置。',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_ConsentChoice.denied),
                child: const Text('不允许'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_ConsentChoice.always),
                child: Text(isDeviceConsent ? '今后自动执行' : '以后允许'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_ConsentChoice.once),
                child: const Text('仅本次允许'),
              ),
            ],
          ),
        ),
      );
      if (mounted && choice != null) {
        final granted = choice != _ConsentChoice.denied;
        var shouldSubmit = true;
        if (choice == _ConsentChoice.always) {
          final scope = AiPersonalDataPermissionScope.fromWireValue(
            consent.consentScope,
          );
          if (scope == null) {
            shouldSubmit = false;
            AppFeedback.error('授权范围无效，请稍后重试', context: context);
          } else {
            try {
              await _permissionService.update(
                scope: scope,
                policy: AiPersonalDataPermissionPolicy.always,
              );
            } on AiPersonalDataPermissionException catch (error) {
              shouldSubmit = false;
              if (mounted) AppFeedback.error(error.message, context: context);
            }
          }
        }
        var submitted = true;
        if (shouldSubmit) {
          submitted = await _provider.submitConsent(granted);
        }
        if (shouldSubmit && !submitted && mounted) {
          _lastConsentDialogKey = '';
          AppFeedback.error(
            _provider.error ?? '提交本次授权失败，请稍后重试',
            context: context,
          );
        } else if (!shouldSubmit) {
          // 长期策略写入失败时允许用户重新打开对话框，不把一次失败锁死。
          _lastConsentDialogKey = '';
        }
      }
      _consentDialogVisible = false;
      if (mounted) _handleRunConsentRequired();
    });
  }

  /// 完全信任模式下，当前 Run 的安全范围已经由长期策略覆盖，
  /// 不再把同一件事重复展示成一次性申请；仍通过服务端 Run consent
  /// 接口确认本轮授权，避免绕过后端的范围校验。
  Future<void> _autoApproveTrustedConsent(AiRunEvent consent) async {
    final key = '${consent.runId}:${consent.seq}:${consent.consentScope}';
    if (key == _lastConsentDialogKey || _provider.submittingConsent) return;
    _lastConsentDialogKey = key;
    final submitted = await _provider.submitConsent(true);
    if (!submitted && mounted) {
      _lastConsentDialogKey = '';
      AppFeedback.error(
        _provider.error ?? '自动继续失败，请重试',
        context: context,
      );
    }
  }

  String _currentPersonalAccountKey() {
    final appUserId = _authProvider?.user?.id.toString() ?? '';
    final sourceAccountId = _eduProvider?.studentId.trim() ?? '';
    return '$appUserId::$sourceAccountId';
  }

  void _handleAccountContextChanged() {
    if (!mounted) return;
    _synchronizePersonalAccount();
    _synchronizeServerAccount();
  }

  void _synchronizeServerAccount() {
    final auth = _authProvider;
    final authKey = auth == null
        ? null
        : '${auth.user?.id}:${auth.isLoggedIn}:${auth.accountSessionEpoch}';

    if (authKey == _lastBootstrapAuthKey) return;
    _lastBootstrapAuthKey = authKey;

    _provider.resetForAccountChange(
      accountId: auth?.isLoggedIn == true ? auth?.user?.id : null,
      sessionGeneration: auth?.accountSessionEpoch ?? 0,
    );
    if (auth?.isLoggedIn == true && auth?.user?.id != null) {
      unawaited(_provider.retryBootstrap());
    }
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
        AppFeedback.info('校园 AI 问答当前已关闭', context: context);
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
      if (mounted && _isCurrentPersonalRequest(requestEpoch)) {
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
        competitionCapabilityProfileSource:
            DioCompetitionCapabilityProfileSource(widget.dio),
        competitionMatchExplanationSource: DioCompetitionMatchExplanationSource(
          widget.dio,
        ),
        competitionPlanActionSource: DioCompetitionPlanActionSource(widget.dio),
        calendarActionSource: DioCalendarActionSource(widget.dio),
        graduationRuleProvider: const _NoVerifiedRuleProvider(),
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
            !competitionAdvisorAccountIndependentSkillIds.contains(
              tool.id,
            ) &&
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
        if (tool.id == ExplainCompetitionMatchesSkill.skillId &&
            flags[AIFeatureFlag.competitionFit] != true) {
          return false;
        }
        return true;
      }).toList(growable: false);
      final unavailableToolReasons = <String, String>{
        if (!hasEduAccount)
          for (final tool in buildStageSixToolDefinitions())
            if (!competitionAdvisorAccountIndependentSkillIds.contains(
                  tool.id,
                ) &&
                (registry.requiredDataTypesFor(tool.id)?.isNotEmpty ?? false))
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
          actionDrafts: outcome.actionArtifacts
              .whereType<CompetitionPlanActionDraft>()
              .toList(growable: false),
          calendarActionDrafts: outcome.actionArtifacts
              .whereType<UserCalendarActionDraft>()
              .toList(growable: false),
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
    final sheetTheme = CampusTheme.withBrandAccent(Theme.of(context));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      builder: (sheetContext) => Theme(
        data: sheetTheme,
        child: ChangeNotifierProvider<AiAssistantProvider>.value(
          value: _provider,
          child: AiHistorySheet(
            onFocusRequest: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _inputFocusNode.requestFocus();
              });
            },
          ),
        ),
      ),
    );
  }

  Future<void> _loadAgentPermissionMode() async {
    try {
      final mode = await _permissionService.getMode();
      if (mounted) {
        setState(() {
          _agentTrusted = mode == AiAgentPermissionMode.trusted;
          _agentPermissionLoaded = true;
          _agentPermissionState = _agentTrusted
              ? AgentPermissionLoadState.trusted
              : AgentPermissionLoadState.ask;
        });
        _handleRunConsentRequired();
      }
    } on AiPersonalDataPermissionException {
      if (mounted) {
        setState(() {
          _agentTrusted = false;
          _agentPermissionLoaded = true;
          _agentPermissionState = AgentPermissionLoadState.unavailable;
        });
        _handleRunConsentRequired();
      }
    }
  }

  Future<void> _showAgentPermissions() async {
    await AiAgentPermissionSheet.show(context, widget.dio);
    if (mounted) unawaited(_loadAgentPermissionMode());
  }

  Future<void> _reauthorizeEduAndRetry() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AccountSecurityScreen(),
      ),
    );
    if (!mounted) return;
    final edu = _eduProvider;
    await edu?.refreshStatus();
    if (!mounted) return;
    if (edu?.isAuthorized == true && edu?.sessionState == 'active') {
      if (_provider.canRetry) _provider.retryLast();
      return;
    }
    AppFeedback.error('教务仍未恢复，请完成重新授权或登录后再试', context: context);
  }

  Future<void> _submitInlineAgentConsent(_ConsentChoice choice) async {
    final consent = _provider.pendingConsent;
    if (consent == null ||
        consent.consentScope.isEmpty ||
        _provider.submittingConsent) {
      return;
    }
    var shouldSubmit = true;
    if (choice == _ConsentChoice.always) {
      final scope = AiPersonalDataPermissionScope.fromWireValue(
        consent.consentScope,
      );
      if (scope == null) {
        shouldSubmit = false;
        if (mounted) AppFeedback.error('授权范围无效，请稍后重试', context: context);
      } else {
        try {
          await _permissionService.update(
            scope: scope,
            policy: AiPersonalDataPermissionPolicy.always,
          );
          unawaited(_loadAgentPermissionMode());
        } on AiPersonalDataPermissionException catch (error) {
          shouldSubmit = false;
          if (mounted) AppFeedback.error(error.message, context: context);
        }
      }
    }
    if (!shouldSubmit) return;
    final submitted = await _provider.submitConsent(
      choice != _ConsentChoice.denied,
    );
    if (!submitted && mounted) {
      AppFeedback.error(
        _provider.error ?? '提交本次授权失败，请稍后重试',
        context: context,
      );
    }
  }

  Future<void> _confirmCompetitionDraft(
    CompetitionPlanActionDraft draft,
  ) async {
    if (!draft.isPending || draft.isExpired) return;
    final dialogTheme = CampusTheme.withBrandAccent(Theme.of(context));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: dialogTheme,
        child: AlertDialog(
          title: const Text('确认加入计划？'),
          content: const Text(
            '加入后会出现在我的计划中，不会自动报名，也不代表学校确认参赛资格。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认加入'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final requestEpoch = _personalSessionEpoch.capture();
    try {
      final updated = await DioCompetitionPlanActionSource(
        widget.dio,
      ).confirm(draft.id);
      if (!_isCurrentPersonalRequest(requestEpoch)) return;
      _replaceCompetitionDraft(updated);
      await _persistPersonalHistory();
      if (mounted) {
        AppFeedback.success('已加入我的竞赛计划', context: context);
      }
    } on CompetitionPlanActionException catch (error) {
      if (!_isCurrentPersonalRequest(requestEpoch)) return;
      if (error.draft != null) {
        _replaceCompetitionDraft(error.draft!);
        await _persistPersonalHistory();
      }
      if (mounted) {
        AppFeedback.error(error.message, context: context);
      }
    } catch (_) {
      if (mounted && _isCurrentPersonalRequest(requestEpoch)) {
        AppFeedback.error('加入计划失败，请稍后重试', context: context);
      }
    }
  }

  Future<void> _confirmCalendarDraft(UserCalendarActionDraft draft) async {
    if (!draft.isPending || draft.isExpired) return;
    final actionLabel = switch (draft.actionType) {
      'calendar_event_update' => '更新日历事件',
      'calendar_event_delete' => '删除日历事件',
      'calendar_reminder_create' => '添加日历提醒',
      _ => '创建日历事件',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('确认$actionLabel？'),
        content: Text(
          draft.actionType == 'calendar_event_delete'
              ? '确认后将删除“${draft.title}”，此操作不会自动恢复。'
              : '确认后才会把“${draft.title}”写入你的个人日历。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('确认$actionLabel'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final requestEpoch = _personalSessionEpoch.capture();
    try {
      final updated =
          await DioCalendarActionSource(widget.dio).confirm(draft.id);
      if (!_isCurrentPersonalRequest(requestEpoch)) return;
      if (updated.postconditionVerified == false) {
        _replaceCalendarDraft(updated);
        await _persistPersonalHistory();
        if (mounted) {
          AppFeedback.error(
            '操作接口已返回，但回读未确认日历是否生效，请刷新日历后再判断',
            context: context,
          );
        }
        return;
      }
      final localReminderScheduled =
          await _scheduleConfirmedCalendarReminder(updated);
      _replaceCalendarDraft(updated);
      await _persistPersonalHistory();
      if (mounted) {
        AppFeedback.info(
          localReminderScheduled ? '日历操作已执行' : '提醒已保存，但当前设备未启用本地系统提醒',
          context: context,
        );
      }
    } on CalendarActionException catch (error) {
      if (!_isCurrentPersonalRequest(requestEpoch)) return;
      if (error.draft != null) _replaceCalendarDraft(error.draft!);
      if (mounted) AppFeedback.error(error.message, context: context);
    } catch (_) {
      if (mounted && _isCurrentPersonalRequest(requestEpoch)) {
        AppFeedback.error('日历操作失败，请稍后重试', context: context);
      }
    }
  }

  Future<void> _cancelCalendarDraft(UserCalendarActionDraft draft) async {
    if (!draft.isPending || draft.isExpired) return;
    final requestEpoch = _personalSessionEpoch.capture();
    try {
      final updated =
          await DioCalendarActionSource(widget.dio).cancel(draft.id);
      if (!_isCurrentPersonalRequest(requestEpoch)) return;
      _replaceCalendarDraft(updated);
      await _persistPersonalHistory();
      if (mounted) AppFeedback.success('日历草稿已取消', context: context);
    } on CalendarActionException catch (error) {
      if (mounted) AppFeedback.error(error.message, context: context);
    } catch (_) {
      if (mounted) AppFeedback.error('取消日历草稿失败，请稍后重试', context: context);
    }
  }

  Future<bool> _scheduleConfirmedCalendarReminder(
    UserCalendarActionDraft draft,
  ) async {
    final event = draft.event;
    final minutes = draft.reminderMinutesBefore;
    if (draft.actionType != 'calendar_reminder_create' ||
        event == null ||
        minutes == null) {
      return true;
    }
    final scheduledTime = event.startAt.subtract(Duration(minutes: minutes));
    if (!scheduledTime.isAfter(DateTime.now())) return true;
    try {
      return await ReminderNotificationClient.instance.scheduleCalendarReminder(
        id: calendarReminderNotificationId(event.id, minutes),
        title: event.title,
        body: event.location.isEmpty ? '日历事件即将开始' : event.location,
        scheduledTime: scheduledTime,
        payload: 'calendar_event:${event.id}:reminder:$minutes',
      );
    } catch (_) {
      // 服务端日历操作已经成功；平台通知失败通过明确的降级反馈告知用户。
      return false;
    }
  }

  void _replaceCalendarDraft(UserCalendarActionDraft updated) {
    _provider.replaceCalendarActionDraft(updated);
    setState(() {
      for (var index = 0; index < _personalMessages.length; index++) {
        final message = _personalMessages[index];
        if (!message.calendarActionDrafts
            .any((item) => item.id == updated.id)) {
          continue;
        }
        _personalMessages[index] = message.copyWith(
          calendarActionDrafts: message.calendarActionDrafts
              .map((item) => item.id == updated.id ? updated : item)
              .toList(growable: false),
        );
      }
      for (var index = 0;
          index < _personalConversationEntries.length;
          index++) {
        final entry = _personalConversationEntries[index];
        if (!entry.message.calendarActionDrafts
            .any((item) => item.id == updated.id)) {
          continue;
        }
        _personalConversationEntries[index] = PersonalConversationEntry(
          message: entry.message.copyWith(
            calendarActionDrafts: entry.message.calendarActionDrafts
                .map((item) => item.id == updated.id ? updated : item)
                .toList(growable: false),
          ),
          evidence: entry.evidence,
        );
      }
    });
  }

  void _replaceCompetitionDraft(CompetitionPlanActionDraft updated) {
    setState(() {
      for (var index = 0; index < _personalMessages.length; index++) {
        final message = _personalMessages[index];
        if (!message.actionDrafts.any((item) => item.id == updated.id)) {
          continue;
        }
        _personalMessages[index] = message.copyWith(
          actionDrafts: message.actionDrafts
              .map((item) => item.id == updated.id ? updated : item)
              .toList(growable: false),
        );
      }
      for (var index = 0;
          index < _personalConversationEntries.length;
          index++) {
        final entry = _personalConversationEntries[index];
        if (!entry.message.actionDrafts.any((item) => item.id == updated.id)) {
          continue;
        }
        _personalConversationEntries[index] = PersonalConversationEntry(
          message: entry.message.copyWith(
            actionDrafts: entry.message.actionDrafts
                .map((item) => item.id == updated.id ? updated : item)
                .toList(growable: false),
          ),
          evidence: entry.evidence,
        );
      }
    });
  }

  void _openCompetitionDetail(int eventId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CompetitionDetailScreen(eventId: eventId),
      ),
    );
  }

  Widget _buildPersonalBody() {
    if (_personalMessages.isEmpty) {
      return AiPersonalEmptyState(
        needsModelConfiguration: _personalNeedsModelConfiguration,
        onConfigureModel: () => _openAiSetting('model'),
        onActionSelected: (prompt) {
          _inputController.text = prompt;
          _inputController.selection = TextSelection.collapsed(
            offset: prompt.length,
          );
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      children: [
        for (final message in _personalMessages)
          AiMessageCard(
            message: message,
            assistantLabel: '个人助手',
            onConfirmDraft: _confirmCompetitionDraft,
            onViewCompetition: _openCompetitionDetail,
            loadSourceContent: widget.service.getSourceContent,
          ),
        if (_personalEvidence.isNotEmpty)
          AiEvidenceCard(evidence: _personalEvidence),
        if (_personalSending)
          const AiTypingStatus(status: '正在先读取 App 数据，再进行分析'),
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
    if (value == 'permissions') {
      await _showAgentPermissions();
      return;
    }
    if (value == 'billing') {
      AppFeedback.info('计费与额度功能暂未开发', context: context);
      return;
    }
    if (value == 'graduation' && !BetaReleasePolicy.aiGraduationAssistant) {
      AppFeedback.info('毕业助手在当前内测版本中暂未开放', context: context);
      return;
    }
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
          dio: widget.dio,
        ),
      'graduation' => GraduationChecklistScreen(
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
      _ => const AIFeatureSettingsScreen(),
    };
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: (_) => page));
    if (saved == true && value == 'model' && mounted) {
      _clearPersonalPermissions();
      setState(() {
        _personalError = null;
        _personalNeedsModelConfiguration = false;
      });
      AppFeedback.success('个人助手模型已保存', context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageTheme = CampusTheme.withBrandAccent(Theme.of(context));
    return Theme(
      data: pageTheme,
      child: ChangeNotifierProvider.value(
        value: _provider,
        child: Consumer<AiAssistantProvider>(
          builder: (context, provider, _) {
            final theme = Theme.of(context);
            final capabilities = provider.capabilities ?? widget.capabilities;
            final quota = provider.quota ?? capabilities.quota;
            final maxInputCharacters = _personalMode
                ? PersonalAIRuntimeLimits.maximumInputCharacters
                : capabilities.maxMessageChars;
            return Scaffold(
              backgroundColor: theme.scaffoldBackgroundColor,
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
                  if (_personalMode)
                    IconButton(
                      tooltip: '更新个人数据',
                      onPressed: () => _openAiSetting('data'),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  if (capabilities.capabilities.isNotEmpty)
                    IconButton(
                      tooltip: '能力范围',
                      onPressed: () => _showCapabilitySheet(capabilities),
                      icon: const Icon(Icons.hub_outlined),
                    ),
                  if (context.read<AuthProvider>().user?.isAdmin == true)
                    IconButton(
                      tooltip: 'AI 调用管理',
                      onPressed: () =>
                          AdminAiControlSheet.show(context, widget.dio),
                      icon: const Icon(Icons.tune_rounded),
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
                        value: 'permissions',
                        label: 'Agent 权限',
                        icon: Icons.admin_panel_settings_outlined,
                      ),
                      AppPopupAction(
                        value: 'billing',
                        label: '计费与额度（暂未开发）',
                        icon: Icons.account_balance_wallet_outlined,
                      ),
                      if (BetaReleasePolicy.aiGraduationAssistant)
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
                            ? AiPublicEmptyState(
                                chatEnabled: capabilities.chatEnabled,
                                quickPrompts: provider.quickPrompts,
                                suggestedPrompts: const [],
                                onRefreshPrompts: provider.refreshQuickPrompts,
                                onPromptSelected: (prompt) {
                                  _inputController.text = prompt;
                                  _inputController.selection =
                                      TextSelection.collapsed(
                                    offset: prompt.length,
                                  );
                                },
                                footer: provider.error == null
                                    ? null
                                    : Padding(
                                        padding: const EdgeInsets.only(
                                          top: 12,
                                        ),
                                        child: AiErrorCard(
                                          message: provider.error!,
                                          actionLabel: provider.canRetry
                                              ? '重试'
                                              : provider.canReconnectRun
                                                  ? '重新连接'
                                                  : '重试加载',
                                          onAction: provider.canRetry
                                              ? provider.retryLast
                                              : provider.canReconnectRun
                                                  ? provider.reconnect
                                                  : provider.retryBootstrap,
                                        ),
                                      ),
                              )
                            : ListView(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 10, 16, 18),
                                children: [
                                  for (final message in provider.messages) ...[
                                    AiMessageCard(
                                      message: message,
                                      onConfirmCalendarDraft:
                                          _confirmCalendarDraft,
                                      onCancelCalendarDraft:
                                          _cancelCalendarDraft,
                                      loadSourceContent:
                                          widget.service.getSourceContent,
                                      onRetrySources: () => unawaited(
                                        _provider.retryMessageSources(message),
                                      ),
                                      onFeedback: (feedback) => _provider
                                          .submitFeedback(message, feedback),
                                    ),
                                    if (message.role == AiMessageRole.user &&
                                        message.requestId ==
                                            provider.activeSubmissionRequestId)
                                      AiAgentExecutionCard(
                                        activities: provider.agentActivities,
                                        rawEvents: provider.agentRawEvents,
                                        event: provider.agentEvent,
                                        running: provider.isRunning,
                                        reconnecting: provider.isReconnecting,
                                        completed: provider.agentFlowCompleted,
                                        onOpenPermissions:
                                            _showAgentPermissions,
                                        onAllowOnce: () => unawaited(
                                          _submitInlineAgentConsent(
                                            _ConsentChoice.once,
                                          ),
                                        ),
                                        onAllowAlways: () => unawaited(
                                          _submitInlineAgentConsent(
                                            _ConsentChoice.always,
                                          ),
                                        ),
                                        onDeny: () => unawaited(
                                          _submitInlineAgentConsent(
                                            _ConsentChoice.denied,
                                          ),
                                        ),
                                        onRetryRefresh: provider.canRetry
                                            ? provider.retryLast
                                            : null,
                                        onUseExistingData:
                                            provider.canUseExistingData
                                                ? provider.useExistingData
                                                : null,
                                        onReauthorizeEdu: provider.canRetry
                                            ? _reauthorizeEduAndRetry
                                            : null,
                                        onUpdateErke:
                                            provider.hasOptionalErkeUpdate
                                                ? _openErkeUpdate
                                                : null,
                                      ),
                                    if (message.role == AiMessageRole.user &&
                                        message.requestId ==
                                            provider
                                                .activeSubmissionRequestId &&
                                        _agentPermissionLoaded &&
                                        !_agentTrusted &&
                                        provider.pendingConsent?.consentScope
                                                .trim()
                                                .isNotEmpty ==
                                            true)
                                      AiAgentPermissionCard(
                                        event: provider.agentEvent ??
                                            provider.pendingConsent!,
                                        onDeny: () => unawaited(
                                          _submitInlineAgentConsent(
                                            _ConsentChoice.denied,
                                          ),
                                        ),
                                        onAllowOnce: () => unawaited(
                                          _submitInlineAgentConsent(
                                            _ConsentChoice.once,
                                          ),
                                        ),
                                        submitting: provider.submittingConsent,
                                      ),
                                  ],
                                  if (provider.error != null)
                                    AiErrorCard(
                                      message: provider.error!,
                                      actionLabel: provider.canRetry
                                          ? '重试'
                                          : provider.canReconnectRun
                                              ? '重新连接'
                                              : '重试加载',
                                      onAction: provider.canRetry
                                          ? provider.retryLast
                                          : provider.canReconnectRun
                                              ? provider.reconnect
                                              : provider.retryBootstrap,
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
                        : capabilities.chatEnabled &&
                            (quota.unlimited || quota.remaining > 0),
                    running:
                        _personalMode ? _personalSending : provider.isRunning,
                    onSend: _submit,
                    onCancel: _personalMode ? _cancelPersonal : provider.cancel,
                    hintText: _personalMode ? '问问你的课程、成绩或计划' : '输入校园问题',
                    showAgentPermissionMode: !_personalMode,
                    agentTrusted: _agentTrusted,
                    agentPermissionState: _agentPermissionState,
                    bridgeStatus: _bridgeStatus,
                    onAgentPermissionTap: _showAgentPermissions,
                    onBridgeRetry: () => unawaited(_retryDeviceBridge()),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _openErkeUpdate() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ErkeScoreScreen(),
      ),
    );
  }

  Future<void> _showCapabilitySheet(AiCapabilities capabilities) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colors = Theme.of(sheetContext).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.42,
          maxChildSize: 0.92,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text('校园 Agent 能力范围',
                  style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                '只读能力可读取公开或已授权数据；日历写入始终先生成草稿并等待确认。',
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 12),
              for (final capability in capabilities.capabilities)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      capability.requiresConfirmation
                          ? Icons.fact_check_outlined
                          : Icons.visibility_outlined,
                      color: capability.available
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    title: Text(capability.description),
                    subtitle: Text(
                      '${capability.id} · ${capability.available ? '可用' : '暂不可用'}'
                      '${capability.requiresConfirmation ? ' · 需要确认' : ''}',
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NoVerifiedRuleProvider implements GraduationRuleProvider {
  const _NoVerifiedRuleProvider();

  @override
  Future<CurriculumRulePackage?> currentRules() async => null;
}
