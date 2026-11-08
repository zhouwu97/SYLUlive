import 'package:flutter/material.dart';
import 'app_card.dart';

/// 独立输入框的底面；输入框本身保留焦点、校验与禁用边框。
class AppInputSurface extends StatelessWidget {
  const AppInputSurface({super.key, required this.child, this.radius = 12});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: AppCardSurface(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1E2226)
                    : Colors.white,
                borderRadius: BorderRadius.circular(radius),
              ),
              child: const SizedBox.expand(),
            ),
          ),
          child,
        ],
      );
}
