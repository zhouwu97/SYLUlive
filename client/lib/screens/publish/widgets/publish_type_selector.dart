import 'package:flutter/material.dart';

/// Type selector for marketplace posts.
///
/// Commit 1: renders the original DropdownButtonFormField.
/// Commit 2: will be replaced with horizontal capsule chips.
class PublishTypeSelector extends StatelessWidget {
  final String currentType;
  final List<String>? allowedTypes;
  final ValueChanged<String> onChanged;

  const PublishTypeSelector({
    super.key,
    required this.currentType,
    this.allowedTypes,
    required this.onChanged,
  });

  bool _typeAllowed(String type) =>
      allowedTypes == null || allowedTypes!.contains(type);

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      decoration: const InputDecoration(labelText: '类型'),
      initialValue: currentType.isEmpty ? null : currentType,
      items: [
        if (_typeAllowed('sell'))
          const DropdownMenuItem(value: 'sell', child: Text('出售')),
        if (_typeAllowed('buy'))
          const DropdownMenuItem(value: 'buy', child: Text('求购')),
        if (_typeAllowed('proxy'))
          const DropdownMenuItem(value: 'proxy', child: Text('代课')),
        if (_typeAllowed('lost'))
          const DropdownMenuItem(value: 'lost', child: Text('求问失物')),
        if (_typeAllowed('found'))
          const DropdownMenuItem(value: 'found', child: Text('寻找失主')),
        if (_typeAllowed('exposure'))
          const DropdownMenuItem(value: 'exposure', child: Text('曝光')),
      ],
      onChanged: (value) => onChanged(value ?? ''),
    );
  }
}
