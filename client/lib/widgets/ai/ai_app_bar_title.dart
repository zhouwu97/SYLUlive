import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

class AiAppBarTitle extends StatelessWidget {
  const AiAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '沈理AI',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: CampusTheme.primaryLight,
            borderRadius: BorderRadius.circular(99),
          ),
          child: const Text(
            '内测',
            style: TextStyle(
              color: CampusTheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
