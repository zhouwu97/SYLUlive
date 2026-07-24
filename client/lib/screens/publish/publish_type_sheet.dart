import 'package:flutter/material.dart';

enum PublishType { waterPost, poll }

class PublishTypeSheet extends StatefulWidget {
  const PublishTypeSheet({super.key});

  static Future<PublishType?> show(BuildContext context) {
    return showModalBottomSheet<PublishType>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const PublishTypeSheet(),
    );
  }

  @override
  State<PublishTypeSheet> createState() => _PublishTypeSheetState();
}

class _PublishTypeSheetState extends State<PublishTypeSheet> {
  bool _selected = false;

  void _choose(PublishType type) {
    if (_selected) return;
    setState(() => _selected = true);
    Navigator.pop(context, type);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181A21) : const Color(0xFFFFFCF8),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('选择发布类型',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('内容会展示在首页，也可从对应版块查看',
              style:
                  TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _PublishChoice(
                  icon: Icons.edit_note,
                  title: '发布水帖',
                  description: '分享生活、学习\n求助与经�?,
                  color: const Color(0xFF16A34A),
                  onTap: () => _choose(PublishType.waterPost),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PublishChoice(
                  icon: Icons.how_to_vote_outlined,
                  title: '发起投票',
                  description: '创建单选或多选\n收集同学意见',
                  color: const Color(0xFF7C3AED),
                  onTap: () => _choose(PublishType.poll),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PublishChoice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _PublishChoice({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 124),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.16 : 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 27),
            const SizedBox(height: 10),
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(description,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }
}
