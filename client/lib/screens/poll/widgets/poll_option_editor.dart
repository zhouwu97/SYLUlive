import 'package:flutter/material.dart';

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
        SizedBox(
          width: 30,
          child: Text('${index + 1}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF7C3AED), fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            maxLength: 50,
            decoration: InputDecoration(
              hintText: '请输入选项',
              counterText: '',
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          height: 44,
          child: IconButton(
            tooltip: '删除选项',
            onPressed: enabled && canDelete ? onDelete : null,
            icon: const Icon(Icons.remove_circle_outline, size: 21),
          ),
        ),
        if (enabled)
          const Icon(Icons.drag_handle, size: 20, color: Colors.grey),
      ],
    );
  }
}
