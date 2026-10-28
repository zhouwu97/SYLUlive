import 'package:flutter/material.dart';

/// 能力入口按内容宽度排布，高度随文字增长，避免横屏卡片被等比拉长。
class AiActionGrid extends StatelessWidget {
  const AiActionGrid({super.key, required this.children, this.minHeight = 96});

  final List<Widget> children;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = constraints.maxWidth >= 760 && textScale <= 1.3 ? 4 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final child in children)
              SizedBox(
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: child,
                ),
              ),
          ],
        );
      },
    );
  }
}
