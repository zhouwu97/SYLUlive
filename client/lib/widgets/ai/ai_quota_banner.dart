import 'package:flutter/material.dart';

import '../../models/ai_quota.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class AiQuotaBanner extends StatelessWidget {
  final AiQuota quota;
  final int maxCharacters;
  const AiQuotaBanner({
    super.key,
    required this.quota,
    required this.maxCharacters,
  });

  String get _message {
    if (quota.remaining <= 0) return '本次额度已用完，请稍后再试';
    return '校园 Agent 额度即将用完 · 剩余 ${quota.remaining} 次';
  }

  bool get _shouldShow {
    if (quota.unlimited) return false;
    if (quota.limit <= 0 || quota.remaining <= 0) {
      return quota.remaining <= 0;
    }
    return quota.remaining / quota.limit <= 0.2;
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldShow) return const SizedBox.shrink();
    final isEmpty = quota.remaining <= 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isEmpty
              ? AppColors.dangerSurfaceLight
              : AppColors.warningSurfaceLight,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: isEmpty ? AppColors.danger : const Color(0xFFF2DDBD),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isEmpty ? Icons.block_outlined : Icons.info_outline_rounded,
              size: 16,
              color: isEmpty ? AppColors.danger : AppColors.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$_message · 每次最多 $maxCharacters 字',
                style: TextStyle(
                  color: isEmpty ? AppColors.danger : const Color(0xFF8A5A12),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
