import 'package:flutter/material.dart';

import '../../providers/ai_assistant_provider.dart';
import '../campus/campus_theme.dart';

class AiInputComposer extends StatefulWidget {
  final TextEditingController controller;
  final int maxCharacters;
  final bool enabled;
  final bool running;
  final ValueChanged<String> onSend;

  const AiInputComposer({
    super.key,
    required this.controller,
    required this.maxCharacters,
    required this.enabled,
    required this.running,
    required this.onSend,
  });

  @override
  State<AiInputComposer> createState() => _AiInputComposerState();
}

class _AiInputComposerState extends State<AiInputComposer> {
  String? _inlineError;

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
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CampusTheme.softBorder)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
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
                      filled: true,
                      fillColor: const Color(0xFFF7F9F8),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                IconButton.filled(
                  onPressed: canSend ? _send : null,
                  style: IconButton.styleFrom(
                    backgroundColor: CampusTheme.primary,
                    disabledBackgroundColor: const Color(0xFFDDE4E2),
                  ),
                  icon: const Icon(Icons.arrow_upward_rounded),
                  tooltip: '发送',
                ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                if (_inlineError != null || overLimit)
                  Expanded(
                    child: Text(
                      _inlineError ?? '最多输入 ${widget.maxCharacters} 个可见字符',
                      style:
                          const TextStyle(color: CampusTheme.red, fontSize: 11),
                    ),
                  )
                else
                  const Spacer(),
                Text(
                  '$_count/${widget.maxCharacters}',
                  style: TextStyle(
                    color: overLimit ? CampusTheme.red : CampusTheme.subText,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
