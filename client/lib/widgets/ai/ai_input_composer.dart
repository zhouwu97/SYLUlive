import 'package:flutter/material.dart';

import '../../providers/ai_assistant_provider.dart';
import '../campus/campus_theme.dart';

class AiInputComposer extends StatefulWidget {
  final TextEditingController controller;
  final int maxCharacters;
  final bool enabled;
  final bool running;
  final ValueChanged<String> onSend;
  final VoidCallback? onCancel;

  const AiInputComposer({
    super.key,
    required this.controller,
    required this.maxCharacters,
    required this.enabled,
    required this.running,
    required this.onSend,
    this.onCancel,
  });

  @override
  State<AiInputComposer> createState() => _AiInputComposerState();
}

class _AiInputComposerState extends State<AiInputComposer> {
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant AiInputComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  int get _count =>
      normalizeAiMessage(widget.controller.text).characters.length;

  void _send() {
    final normalized = normalizeAiMessage(widget.controller.text);
    setState(() {
      if (normalized.isEmpty) {
        _inlineError = '请输入问题';
      } else if (normalized.characters.length > widget.maxCharacters) {
        _inlineError = '最多输入 ${widget.maxCharacters} 个可见字符';
      } else {
        _inlineError = null;
      }
    });
    if (_inlineError == null) widget.onSend(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final overLimit = _count > widget.maxCharacters;
    final canSend =
        widget.enabled && !widget.running && _count > 0 && !overLimit;
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 56,
              padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      enabled: widget.enabled && !widget.running,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: canSend ? (_) => _send() : null,
                      onChanged: (_) => setState(() => _inlineError = null),
                      decoration: InputDecoration(
                        hintText: widget.enabled ? '问一个校园问题' : '基础设施测试中',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$_count/${widget.maxCharacters}',
                    style: TextStyle(
                      color: overLimit ? colors.error : colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton.filled(
                      onPressed: widget.running
                          ? widget.onCancel
                          : (canSend ? _send : null),
                      style: IconButton.styleFrom(
                        backgroundColor: colors.primary,
                        disabledBackgroundColor: colors.surfaceContainerHighest,
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      icon: Icon(
                        widget.running
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        size: 20,
                      ),
                      tooltip: widget.running ? '取消回答' : '发送',
                    ),
                  ),
                ],
              ),
            ),
            if (_inlineError != null || overLimit)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 12),
                child: Text(
                  _inlineError ?? '最多输入 ${widget.maxCharacters} 个可见字符',
                  style: TextStyle(color: colors.error, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
