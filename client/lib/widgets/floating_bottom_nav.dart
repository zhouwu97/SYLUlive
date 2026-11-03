import 'package:flutter/material.dart';
import 'liquid_bottom_nav.dart';

/// Ordinary floating navigation: no scene capture, shader, or liquid springs.
class FloatingBottomNav extends StatelessWidget {
  const FloatingBottomNav(
      {super.key,
      required this.currentIndex,
      required this.onTap,
      this.badges = const {}});
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Map<int, bool> badges;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  color:
                      dark ? const Color(0xff252a32) : const Color(0xfff4f6fa),
                  elevation: 3,
                  borderRadius: BorderRadius.circular(32),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                      height: 64,
                      child: Row(
                          children: List.generate(5, (i) {
                        final selected = currentIndex == i;
                        final color = selected
                            ? (dark
                                ? const Color(0xff84baff)
                                : const Color(0xff1765da))
                            : (dark ? Colors.white70 : const Color(0xff4c5360));
                        return Expanded(
                            child: Semantics(
                          button: true,
                          selected: selected,
                          label:
                              '${LiquidBottomNav.labels[i]}${badges[i] == true ? '，有新消息' : ''}',
                          child: InkWell(
                            key: ValueKey('bottom-nav-item-$i'),
                            onTap: () => onTap(i),
                            child: ExcludeSemantics(
                                child: Container(
                              margin: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                  color: selected
                                      ? color.withValues(alpha: .10)
                                      : null,
                                  borderRadius: BorderRadius.circular(28)),
                              child: Center(
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    Badge(
                                        isLabelVisible: badges[i] == true,
                                        child: Icon(LiquidBottomNav.icons[i],
                                            color: color, size: 24)),
                                    const SizedBox(height: 3),
                                    Text(LiquidBottomNav.labels[i],
                                        maxLines: 1,
                                        style: TextStyle(
                                            fontSize: 11, color: color)),
                                  ])),
                            )),
                          ),
                        ));
                      }))),
                ),
              )),
        ));
  }
}
