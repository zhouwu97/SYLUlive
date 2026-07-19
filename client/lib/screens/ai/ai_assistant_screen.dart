import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/ai_capabilities.dart';
import '../../providers/ai_assistant_provider.dart';
import '../../services/ai_assistant_service.dart';
import '../../utils/app_navigator.dart';
import '../../widgets/ai/ai_empty_state.dart';
import '../../widgets/ai/ai_error_card.dart';
import '../../widgets/ai/ai_input_composer.dart';
import '../../widgets/ai/ai_message_card.dart';
import '../../widgets/ai/ai_quota_banner.dart';
import '../../widgets/ai/ai_typing_status.dart';
import '../../widgets/campus/campus_theme.dart';

class AiAssistantScreen extends StatefulWidget {
  final AiCapabilities capabilities;
  final AiAssistantService service;

  const AiAssistantScreen({
    super.key,
    required this.capabilities,
    required this.service,
  });

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late final AiAssistantProvider _provider;
  final TextEditingController _inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _provider = AiAssistantProvider(
      widget.service,
      initialCapabilities: widget.capabilities,
    );
  }

  @override
  void dispose() {
    _inputController.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _openSchedule() {
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widgetTabSwitch.value++;
    });
  }

  void _submit(String message) {
    final result = _provider.submit(message);
    if (result == AiSubmitResult.accepted) _inputController.clear();
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
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: AiQuotaBanner(
                    quota: quota,
                    maxCharacters: capabilities.maxMessageChars,
                  ),
                ),
                Expanded(
                  child: provider.messages.isEmpty
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: AiErrorCard(message: provider.error!),
                              ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
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
                                actionLabel: provider.error!.contains('课表')
                                    ? '去课表'
                                    : null,
                                onAction: _openSchedule,
                              ),
                          ],
                        ),
                ),
                AiInputComposer(
                  controller: _inputController,
                  maxCharacters: capabilities.maxMessageChars,
                  enabled: capabilities.chatEnabled && quota.remaining > 0,
                  running: provider.isRunning,
                  onSend: _submit,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
