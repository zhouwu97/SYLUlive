import 'package:flutter/material.dart';

import '../../features/ai_runtime/ai_model_provider.dart';
import '../../features/ai_runtime/ai_model_runtime.dart';
import '../../features/ai_runtime/ai_provider_storage.dart';
import '../../main.dart';
import '../../services/account_session_cleanup_coordinator.dart';
import '../../services/ai_assistant_service.dart';
import 'ai_model_settings_screen.dart';

class AIModelChatScreen extends StatefulWidget {
  const AIModelChatScreen({
    super.key,
    required this.appUserId,
  });

  final String appUserId;

  @override
  State<AIModelChatScreen> createState() => _AIModelChatScreenState();
}

class _AIModelChatScreenState extends State<AIModelChatScreen> {
  late final AIModelChatController _controller;
  final TextEditingController _inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settingsStore = AIProviderSettingsStore(appUserId: widget.appUserId);
    _controller = AIModelChatController(
      settingsStore: settingsStore,
      providerFactory: AIModelProviderFactory(
        settingsStore: settingsStore,
        campusService: AiAssistantService(getSharedDio()),
      ),
    );
    AccountSessionCleanupCoordinator.instance.register(
      this,
      _controller.closeAccountContext,
    );
    _controller.load();
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AIModelSettingsScreen(appUserId: widget.appUserId),
      ),
    );
    if (changed == true) await _controller.load();
  }

  Future<void> _send() async {
    final text = _inputController.text;
    if (text.trim().isEmpty || _controller.sending) return;
    _inputController.clear();
    await _controller.send(text);
  }

  @override
  void dispose() {
    AccountSessionCleanupCoordinator.instance.unregister(this);
    _inputController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(_controller.config?.kind.displayName ?? '普通聊天'),
          actions: [
            IconButton(
              tooltip: '模型设置',
              onPressed: _openSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: _controller.loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(child: _buildConversation(context)),
                  if (_controller.error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _controller.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭提示',
                            onPressed: _controller.clearError,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: TextField(
                        controller: _inputController,
                        enabled:
                            _controller.isConfigured && !_controller.sending,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText:
                              _controller.isConfigured ? '输入消息' : '请先设置模型',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: '发送',
                            onPressed:
                                _controller.isConfigured && !_controller.sending
                                    ? _send
                                    : null,
                            icon: _controller.sending
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.send_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildConversation(BuildContext context) {
    if (!_controller.isConfigured) {
      return Center(
        child: FilledButton.icon(
          onPressed: _openSettings,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('设置模型'),
        ),
      );
    }
    if (_controller.messages.isEmpty) {
      return const Center(child: Text('开始新的对话'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _controller.messages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _MessageBubble(
        message: _controller.messages[index],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AIModelChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AIModelMessageRole.user;
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isUser
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(message.content),
          ),
        ),
      ),
    );
  }
}
