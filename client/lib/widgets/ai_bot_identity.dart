import 'package:flutter/material.dart';

import '../models/user.dart';
import '../theme/app_radius.dart';

/// 系统归属来自服务端账号类型，不能从昵称中的「AI」推断。
class AiBotIdentity extends StatelessWidget {
  const AiBotIdentity({super.key, required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    if (user?.isAiBot != true) return const SizedBox.shrink();
    final attribution = user!.aiBotCreatorLabel;
    return Semantics(
      label: '系统AI机器人，AI 等级 ${user!.level}，$attribution',
      child: ExcludeSemantics(
        child: Tooltip(
          message: '系统身份与创建者来自平台记录，不随昵称修改。$attribution',
          child: Padding(
            padding: const EdgeInsets.only(top: 3, bottom: 1),
            child: _AiBotTag(owner: user!.aiBotOwnerPrefix, level: user!.level),
          ),
        ),
      ),
    );
  }
}

/// AI 等级配色：Lv.1–8 依次为天蓝、蓝青渐变、青绿、雾靛、琥珀、珊瑚、樱粉、黑白。
class _AiTagPalette {
  const _AiTagPalette({
    required this.bg,
    required this.border,
    required this.text,
    required this.chip,
    this.chipEnd,
    required this.darkBg,
    required this.darkText,
    this.darkChip,
  });

  final Color bg, border, text, chip, darkBg, darkText;
  final Color? chipEnd, darkChip;
}

const _aiTagPalettes = [
  _AiTagPalette(
      bg: Color(0xFFEAF2FF),
      border: Color(0x333B82F6),
      text: Color(0xFF2563EB),
      chip: Color(0xFF3B82F6),
      darkBg: Color(0xFF1B2638),
      darkText: Color(0xFF93C5FD)),
  _AiTagPalette(
      bg: Color(0xFFE8F6FD),
      border: Color(0x3306B6D4),
      text: Color(0xFF0E7490),
      chip: Color(0xFF3B82F6),
      chipEnd: Color(0xFF06B6D4),
      darkBg: Color(0xFF16282F),
      darkText: Color(0xFF67E8F9)),
  _AiTagPalette(
      bg: Color(0xFFE6FAF7),
      border: Color(0x330D9488),
      text: Color(0xFF0F766E),
      chip: Color(0xFF14B8A6),
      darkBg: Color(0xFF142A28),
      darkText: Color(0xFF5EEAD4)),
  _AiTagPalette(
      bg: Color(0xFFEEF0FA),
      border: Color(0x334F5BD5),
      text: Color(0xFF4338CA),
      chip: Color(0xFF5B67E0),
      darkBg: Color(0xFF1F2238),
      darkText: Color(0xFFA5B4FC)),
  _AiTagPalette(
      bg: Color(0xFFFFF4E0),
      border: Color(0x33D97706),
      text: Color(0xFFB45309),
      chip: Color(0xFFF59E0B),
      darkBg: Color(0xFF2E2414),
      darkText: Color(0xFFFCD34D)),
  _AiTagPalette(
      bg: Color(0xFFFFF0EA),
      border: Color(0x33F25F3A),
      text: Color(0xFFC2410C),
      chip: Color(0xFFF26B4A),
      darkBg: Color(0xFF2F1D18),
      darkText: Color(0xFFFDBA9C)),
  _AiTagPalette(
      bg: Color(0xFFFFEFF3),
      border: Color(0x33E11D48),
      text: Color(0xFFBE123C),
      chip: Color(0xFFF43F5E),
      darkBg: Color(0xFF2E1820),
      darkText: Color(0xFFFDA4AF)),
  _AiTagPalette(
      bg: Color(0xFFF2F3F5),
      border: Color(0x221F2329),
      text: Color(0xFF1F2329),
      chip: Color(0xFF1F2329),
      darkBg: Color(0xFF26282C),
      darkText: Color(0xFFE5E7EB),
      darkChip: Color(0xFFF3F4F6)),
];

/// 单个胶囊说明归属与 AI 等级：「纯合子的 ✦AI Lv.3」，颜色随 AI 等级变化。
class _AiBotTag extends StatelessWidget {
  const _AiBotTag({required this.owner, required this.level});

  final String owner;
  final int level;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = _aiTagPalettes[(level - 1).clamp(0, _aiTagPalettes.length - 1)];
    final chip = dark ? (p.darkChip ?? p.chip) : p.chip;
    final chipForeground =
        dark && p.darkChip != null ? const Color(0xFF111111) : Colors.white;
    return Container(
      padding: EdgeInsets.fromLTRB(owner.isEmpty ? 2.5 : 8, 2.5, 2.5, 2.5),
      decoration: BoxDecoration(
        color: dark ? p.darkBg : p.bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: p.border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (owner.isNotEmpty) ...[
            Flexible(
              child: Text(
                owner,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  color: dark ? p.darkText : p.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: p.chipEnd == null ? chip : null,
              gradient: p.chipEnd == null
                  ? null
                  : LinearGradient(colors: [chip, p.chipEnd!]),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 10, color: chipForeground),
                const SizedBox(width: 2),
                Text(
                  'AI Lv.$level',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    letterSpacing: 0.2,
                    color: chipForeground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
