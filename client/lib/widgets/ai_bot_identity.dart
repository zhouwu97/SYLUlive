import 'package:flutter/material.dart';

import '../models/user.dart';
import '../theme/app_radius.dart';

/// 系统归属来自服务端账号类型，不能从昵称中的「AI」推断。
class AiBotIdentity extends StatelessWidget {
  const AiBotIdentity({super.key, required this.user, this.style});

  final User? user;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (user?.isAiBot != true) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final attribution = user!.aiBotCreatorLabel;
    final textStyle = style ??
        theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
    return Semantics(
      label: '系统AI机器人，$attribution',
      child: ExcludeSemantics(
        child: Tooltip(
          message: '系统身份与创建者来自平台记录，不随昵称修改。$attribution',
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  border: Border.all(color: theme.colorScheme.primary),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smart_toy_outlined,
                        size: 13, color: theme.colorScheme.onPrimaryContainer),
                    const SizedBox(width: 4),
                    Text(
                      'AI机器人',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                attribution,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
