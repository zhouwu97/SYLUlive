import 'package:flutter/material.dart';

import '../../services/emoji_recent_service.dart';
import 'emoji_catalog.dart';

/// 内嵌式 Emoji 选择面板，只负责选择和删除回调，不负责发送消息。
class AppEmojiPanel extends StatefulWidget {
  final ValueChanged<String> onEmojiSelected;
  final VoidCallback onBackspace;
  final bool enabled;
  final EmojiRecentService? recentService;

  const AppEmojiPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onBackspace,
    this.enabled = true,
    this.recentService,
  });

  @override
  State<AppEmojiPanel> createState() => _AppEmojiPanelState();
}

class _AppEmojiPanelState extends State<AppEmojiPanel> {
  int _categoryIndex = 0;
  List<String> _recent = const <String>[];

  EmojiRecentService get _recentService =>
      widget.recentService ?? EmojiRecentService.instance;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final recent = await _recentService.load();
    if (mounted) setState(() => _recent = recent);
  }

  List<String> get _activeEmojis {
    if (_categoryIndex == 0) return _recent;
    return appEmojiCatalog[appEmojiCategoryNames[_categoryIndex]] ??
        const <String>[];
  }

  Future<void> _selectEmoji(String emoji) async {
    if (!widget.enabled) return;
    widget.onEmojiSelected(emoji);
    await _recentService.record(emoji);
    if (mounted) {
      final recent = await _recentService.load();
      if (mounted) setState(() => _recent = recent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C202A) : const Color(0xFFF8F9FC);
    final muted = isDark ? Colors.white60 : Colors.black54;
    return Material(
      color: surface,
      child: Column(
        children: [
          SizedBox(
            height: 46,
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: appEmojiCategoryNames.length,
                    itemBuilder: (context, index) {
                      final name = appEmojiCategoryNames[index];
                      final selected = index == _categoryIndex;
                      return InkWell(
                        onTap: widget.enabled
                            ? () => setState(() => _categoryIndex = index)
                            : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                appEmojiCategoryIcons[name],
                                size: 18,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : muted,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : muted,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Tooltip(
                  message: '删除前一个字符',
                  child: IconButton(
                    onPressed: widget.enabled ? widget.onBackspace : null,
                    icon: const Icon(Icons.backspace_outlined),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _activeEmojis.isEmpty
                ? Center(
                    child: Text(
                      '暂无最近使用',
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 56,
                          mainAxisExtent: 48,
                        ),
                        itemCount: _activeEmojis.length,
                        itemBuilder: (context, index) {
                          final emoji = _activeEmojis[index];
                          return Semantics(
                            button: true,
                            label: '插入表情 $emoji',
                            child: InkWell(
                              onTap: widget.enabled
                                  ? () => _selectEmoji(emoji)
                                  : null,
                              borderRadius: BorderRadius.circular(8),
                              child: Center(
                                child: Text(
                                  emoji,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontFamilyFallback: [
                                      'Noto Color Emoji',
                                      'Segoe UI Emoji',
                                      'Apple Color Emoji',
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
