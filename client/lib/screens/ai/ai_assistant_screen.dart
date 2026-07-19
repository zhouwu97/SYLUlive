import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/ai_capabilities.dart';
import '../../providers/ai_assistant_provider.dart';
import '../../services/ai_assistant_service.dart';
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
    unawaited(_provider.initialize());
  }

  @override
  void dispose() {
    _inputController.dispose();
    _provider.dispose();
    super.dispose();
  }

  void _submit(String message) {
    final result = _provider.submit(message);
    if (result == AiSubmitResult.accepted && mounted) _inputController.clear();
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
                IconButton(
                  tooltip: '历史会话',
                  onPressed: _showConversations,
                  icon: const Icon(Icons.history_rounded),
                ),
              ],
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
                                actionLabel: provider.canRetry ? '重试' : '重新连接',
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
                  enabled: capabilities.chatEnabled && quota.remaining > 0,
                  running: provider.isRunning,
                  onSend: _submit,
                  onCancel: provider.cancel,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
