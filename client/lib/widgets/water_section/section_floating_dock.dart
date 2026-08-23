import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 版块页只保留一个与首页一致的编辑 FAB。
class SectionFloatingDock extends StatelessWidget {
  final VoidCallback onCompose;

  const SectionFloatingDock({
    super.key,
    required this.onCompose,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '发布帖子',
      child: SizedBox(
        width: 52,
        height: 52,
        child: FloatingActionButton(
          heroTag: 'section_compose_fab',
          onPressed: onCompose,
          backgroundColor: AppColors.brandPrimary,
          foregroundColor: Colors.white,
          elevation: 2,
          shape: const CircleBorder(),
          child: const Icon(Icons.edit_rounded, size: 22),
        ),
      ),
    );
  }
}
