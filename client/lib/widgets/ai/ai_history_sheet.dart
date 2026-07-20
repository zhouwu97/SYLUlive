import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/ai_assistant_provider.dart';

class AiHistorySheet extends StatelessWidget {
  const AiHistorySheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AiAssistantProvider>(
      builder: (context, provider, _) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.62,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '历史会话',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '新建会话',
                        onPressed: () {
                          provider.startNewConversation();
                          Navigator.pop(context);
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
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                              itemCount: provider.conversations.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, index) {
                                final conversation = provider.conversations[index];
                                final selected = conversation.id == provider.conversationId;
                                return ListTile(
                                  selected: selected,
                                  leading: const Icon(Icons.forum_outlined),
                                  title: Text(
                                    conversation.title.isEmpty ? '新会话' : conversation.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    tooltip: '删除会话',
                                    icon: const Icon(Icons.delete_outline_rounded),
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: const Text('删除会话？'),
                                          content: const Text('删除后无法恢复其中的问答记录。'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(dialogContext, false),
                                                child: const Text('取消')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(dialogContext, true),
                                                child: const Text('删除')),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true) {
                                        await provider.deleteConversation(conversation.id);
                                      }
                                    },
                                  ),
                                  onTap: () {
                                    provider.openConversation(conversation.id);
                                    Navigator.pop(context);
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
    );
  }
}
