import 'package:flutter/material.dart';
import '../../../widgets/campus/campus_theme.dart';

class PollOptionEditor extends StatelessWidget {
  final int index;
  final TextEditingController controller;
  final bool enabled;
  final bool canDelete;
  final VoidCallback onDelete;

  const PollOptionEditor({
    super.key,
    required this.index,
    required this.controller,
    required this.enabled,
    required this.canDelete,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      key: ValueKey(controller),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: CampusTheme.primaryLight,
            shape: BoxShape.circle,
          ),
          child: Text(
            '${index + 1}',
            style: const TextStyle(
              color: CampusTheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: controller,
              enabled: enabled,
              maxLength: 50,
              decoration: InputDecoration(
                hintText: '请输入选项',
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            tooltip: '删除选项',
            onPressed: enabled && canDelete ? onDelete : null,
            icon: Icon(
              Icons.remove_circle_outline, 
              size: 21,
              color: enabled && canDelete ? const Color(0xFFE54848).withValues(alpha: 0.8) : Colors.grey,
            ),
          ),
        ),
        if (enabled)
          const Icon(Icons.drag_handle, size: 18, color: Colors.grey),
      ],
    );
  }
}
