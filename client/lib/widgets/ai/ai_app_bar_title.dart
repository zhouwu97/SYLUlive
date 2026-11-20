import 'package:flutter/material.dart';

import '../../theme/app_theme_tokens.dart';
import '../../theme/app_palette.dart';

class AiAppBarTitle extends StatelessWidget {
  const AiAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '沈理AI',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppThemeTokens.of(context).primaryContainer,
            borderRadius: BorderRadius.circular(AppShape.of(context).pill),
          ),
          child: Text(
            '内测',
            style: TextStyle(
              color: AppThemeTokens.of(context).primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
