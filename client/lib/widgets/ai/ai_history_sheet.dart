import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/ai_assistant_provider.dart';
import '../../utils/app_feedback.dart';
import 'ai_history_tile.dart';

class AiHistorySheet extends StatefulWidget {
  final VoidCallback? onFocusRequest;

  const AiHistorySheet({super.key, this.onFocusRequest});

  @override
  State<AiHistorySheet> createState() => _AiHistorySheetState();
}

class _AiHistorySheetState extends State<AiHistorySheet> {
  String? _deletingId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.52,
      minChildSize: 0.38,
      maxChildSize: 0.82,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Consumer<AiAssistantProvider>(
            builder: (context, provider, _) {
              return Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '历史会话',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton.filled(
                            tooltip: '新建会话',
                            onPressed: () {
                              provider.startNewConversation();
                              Navigator.pop(context);
                              widget.onFocusRequest?.call();
                            },
                            icon: const Icon(Icons.add_rounded, size: 22),
                            style: IconButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              backgroundColor: colors.surfaceContainerHighest,
                              foregroundColor: colors.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: provider.loadingConversations
                        ? const Center(child: CircularProgressIndicator())
                        : provider.conversations.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      '暂无历史会话',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '提出问题后，会话会保存在这里',
                                      style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 13),
                                    ),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                      onPressed: () {
                                        provider.startNewConversation();
                                        Navigator.pop(context);
                                        widget.onFocusRequest?.call();
                                      },
                                      child: const Text('开始新会话'),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: provider.conversations.length,
                                itemBuilder: (_, index) {
                                  final conversation =
                                      provider.conversations[index];
                                  final selected = conversation.id ==
                                      provider.conversationId;
                                  return AiHistoryTile(
                                    conversation: conversation,
                                    isSelected: selected,
                                    isDeleting: _deletingId == conversation.id,
                                    onTap: () async {
                                      if (provider.isRunning) {
                                        AppFeedback.info(
                                          '请等待当前回答完成或先停止生成',
                                          context: context,
                                        );
                                        return;
                                      }
                                      await provider
                                          .openConversation(conversation.id);
                                      if (!context.mounted ||
                                          provider.error != null) {
                                        return;
                                      }
                                      if (context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                                    onDelete: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: const Text('删除会话？'),
                                          content:
                                              const Text('删除后无法恢复其中的问答记录。'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(
                                                    dialogContext, false),
                                                child: const Text('取消')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(
                                                    dialogContext, true),
                                                style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        colors.error),
                                                child: const Text('删除')),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true && mounted) {
                                        setState(() =>
                                            _deletingId = conversation.id);
                                        try {
                                          await provider.deleteConversation(
                                              conversation.id);
                                        } catch (e) {
                                          if (!context.mounted) {
                                            return;
                                          }
                                          AppFeedback.error(
                                            '删除失败，请重试',
                                            context: context,
                                          );
                                        } finally {
                                          if (mounted) {
                                            setState(() => _deletingId = null);
                                          }
                                        }
                                      }
                                    },
                                  );
                                },
                              ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
