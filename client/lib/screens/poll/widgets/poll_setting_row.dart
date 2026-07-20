import 'package:flutter/material.dart';
import '../../../widgets/campus/campus_theme.dart';

class PollSettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final bool showDivider;

  const PollSettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(icon, size: 19, color: CampusTheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2328))),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: const TextStyle(
                                fontSize: 11.5, color: Color(0xFF747B82))),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                trailing,
              ],
            ),
          ),
        ),
        if (showDivider)
          const Padding(
            padding: EdgeInsets.only(left: 47),
            child: Divider(height: 1, thickness: 0.5, color: Color(0xFFE2EFEA)),
          ),
      ],
    );
  }
}
