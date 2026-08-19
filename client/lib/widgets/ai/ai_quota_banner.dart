import 'package:flutter/material.dart';

import '../../models/ai_quota.dart';

class AiQuotaBanner extends StatelessWidget {
  final AiQuota quota;
  final int maxCharacters;
  const AiQuotaBanner({
    super.key,
    required this.quota,
    required this.maxCharacters,
  });

  String get _message {
    if (quota.unlimited) {
      return '使用次数不限';
    }
    if (quota.remaining >= quota.limit) {
      return '本小时可提问 ${quota.remaining} 次';
    }
    if (quota.remaining == 1) {
      return '本小时仅剩 1 次';
    }
    if (quota.remaining > 1) {
      return '本小时剩余 ${quota.remaining} 次';
    }
    final resetAt = quota.resetAt;
    if (resetAt == null) return '本小时额度已用完，恢复时间以服务端为准';
    final hour = resetAt.hour.toString().padLeft(2, '0');
    final minute = resetAt.minute.toString().padLeft(2, '0');
    return '本小时次数已用完 · 下一次可提问：$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Container(
        width: double.infinity,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$_message · 每次最多 $maxCharacters 字',
                style: TextStyle(
                  color: colors.onPrimaryContainer,
                  fontSize: 12.5,
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
