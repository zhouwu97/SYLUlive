import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/lottery.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_style.dart';
import '../../theme/app_theme_tokens.dart';
import '../app_cached_image.dart';
import '../app_card.dart';
import '../cached_avatar.dart';
import '../campus/campus_theme.dart';

/// 抽奖页、超管抽奖管理与发布预览共用的组件。
/// 颜色全部来自主题 Token；成功、警告、危险等状态色保持语义色，不随主题变化。

const lotteryBeijingOffset = Duration(hours: 8);

/// 使用 UTC 对象承载北京时间的日历字段，避免设备时区影响日期运算。
DateTime lotteryBeijingWallTime(DateTime instant) =>
    instant.toUtc().add(lotteryBeijingOffset);

/// 北京时间展示；[withYear] 为 false 时省略年份。
String formatLotteryBeijing(DateTime value, {bool withYear = true}) {
  final bj = lotteryBeijingWallTime(value);
  String two(int v) => v.toString().padLeft(2, '0');
  final date =
      '${two(bj.month)}-${two(bj.day)} ${two(bj.hour)}:${two(bj.minute)}';
  return withYear ? '${bj.year}-$date' : date;
}

String formatLotteryBeijingRfc3339(DateTime wallTime) {
  final minute = DateTime.utc(wallTime.year, wallTime.month, wallTime.day,
      wallTime.hour, wallTime.minute);
  return '${minute.toIso8601String().split('.').first}+08:00';
}

/// 距今晚 20 点不足半小时，则将该选项顺延到明晚。
List<(String, DateTime)> lotteryQuickDrawTimes(DateTime instant) {
  final now = lotteryBeijingWallTime(instant);
  final tonight = DateTime.utc(now.year, now.month, now.day, 20);
  return [
    if (tonight.difference(now) >= const Duration(minutes: 30))
      ('今晚 20:00', tonight)
    else
      ('明晚 20:00', DateTime.utc(now.year, now.month, now.day + 1, 20)),
    ('明天 12:00', DateTime.utc(now.year, now.month, now.day + 1, 12)),
    ('3 天后', DateTime.utc(now.year, now.month, now.day + 3, 12)),
  ];
}

/// 把「1.xxx 2.xxx」这类连写说明拆成条目：编号须在行首、空白或句读之后，从 1 开始连续且至少两条才拆，
/// 编号前的文字作为引导语；不满足时整段原样返回。
({String lead, List<String> items}) parseLotteryDescription(String raw) {
  final text = raw.trim();
  final pattern = RegExp(r'(?:^|(?<=[\s；;。，,]))(\d{1,2})\s*[.．、](?!\d)');
  final marks = <RegExpMatch>[];
  for (final m in pattern.allMatches(text)) {
    if (int.parse(m.group(1)!) == marks.length + 1) marks.add(m);
  }
  if (marks.length < 2) return (lead: text, items: const <String>[]);
  final items = <String>[];
  for (var i = 0; i < marks.length; i++) {
    final end = i + 1 < marks.length ? marks[i + 1].start : text.length;
    items.add(text
        .substring(marks[i].end, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim());
  }
  return (lead: text.substring(0, marks.first.start).trim(), items: items);
}

enum LotteryTone { success, warning, danger, neutral }

/// 状态语义色：前景与底色，明暗模式各一套。
(Color, Color) lotteryToneColors(BuildContext context, LotteryTone tone) {
  final tokens = AppThemeTokens.of(context);
  final dark = tokens.isDark;
  return switch (tone) {
    LotteryTone.success => (
        dark ? const Color(0xFF4CC98A) : AppColors.success,
        dark ? AppColors.successSurfaceDark : AppColors.successSurfaceLight,
      ),
    LotteryTone.warning => (
        dark ? const Color(0xFFF5B544) : const Color(0xFFB76E00),
        dark ? AppColors.warningSurfaceDark : AppColors.warningSurfaceLight,
      ),
    LotteryTone.danger => (
        dark ? const Color(0xFFFF7070) : AppColors.danger,
        dark ? AppColors.dangerSurfaceDark : AppColors.dangerSurfaceLight,
      ),
    LotteryTone.neutral => (tokens.textSecondary, tokens.surfaceMuted),
  };
}

LotteryTone lotteryStatusTone(int status) => switch (status) {
      LotteryEvent.statusOngoing => LotteryTone.success,
      _ => LotteryTone.neutral,
    };

/// 主题卡片：共享卡片材质（描边、透明度、淡底图）。
class LotteryCard extends StatelessWidget {
  const LotteryCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => AppCardSurface(
        width: double.infinity,
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: CampusTheme.themedCardDecoration(context),
        child: child,
      );
}

class LotterySectionTitle extends StatelessWidget {
  const LotterySectionTitle(this.text, {super.key, this.size = 16});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => ThemeSectionTitle(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w700,
          color: AppThemeTokens.of(context).textPrimary,
        ),
      );
}

class LotteryStatusChip extends StatelessWidget {
  const LotteryStatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.dot = true,
    this.solid = false,
  });

  final String label;
  final LotteryTone tone;
  final bool dot;

  /// 叠在图片上时用卡片底色，保证可读。
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = lotteryToneColors(context, tone);
    return Container(
      padding: EdgeInsets.fromLTRB(dot ? 8 : 10, 4, 10, 4),
      decoration: BoxDecoration(
        color: solid
            ? AppThemeTokens.of(context).card.withValues(alpha: 0.94)
            : bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style:
                TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

/// 奖品图；没有图片或加载失败时显示主题的抽奖图标，主题未提供则显示礼盒图标。
class LotteryPrizeArt extends StatelessWidget {
  const LotteryPrizeArt({
    super.key,
    required this.imagePath,
    this.localImageBytes,
    this.radius = 14,
    this.iconSize = 56,
  });

  final String imagePath;
  final Uint8List? localImageBytes;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final fallback = _LotteryGiftArt(iconSize: iconSize);
    final bytes = localImageBytes;
    final Widget content;
    if (bytes != null) {
      content = Image.memory(bytes, fit: BoxFit.cover);
    } else if (imagePath.isEmpty) {
      content = fallback;
    } else {
      content = AppCachedImage.public(
        imageUrl: ApiConstants.fullUrl(imagePath),
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: content,
    );
  }
}

class _LotteryGiftArt extends StatelessWidget {
  const _LotteryGiftArt({required this.iconSize});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return ColoredBox(
      color: tokens.primaryContainer,
      child: Center(
        child: AppThemeStyle.of(context)
                .serviceIcon(context, 'lottery', size: iconSize) ??
            Icon(Icons.card_giftcard_rounded,
                size: iconSize * 0.8, color: tokens.onPrimaryContainer),
      ),
    );
  }
}

/// 用户端 Hero：奖品图、名称、倒计时或开奖结果、关键数据。发布页预览复用。
class LotteryHeroCard extends StatelessWidget {
  const LotteryHeroCard({
    super.key,
    required this.event,
    required this.participantCount,
    required this.remaining,
    this.myWeight,
    this.localImageBytes,
  });

  final LotteryEvent event;
  final int participantCount;

  /// 距开奖剩余时间；仅进行中的活动使用。
  final Duration remaining;

  /// 已参与时的实时权重；未参与为 null。
  final int? myWeight;
  final Uint8List? localImageBytes;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return LotteryCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 338 / 196,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LotteryPrizeArt(
                    imagePath: event.prizeImage,
                    localImageBytes: localImageBytes,
                    iconSize: 96),
                Positioned(
                  left: 10,
                  top: 10,
                  child: LotteryStatusChip(
                    label: event.statusLabel,
                    tone: lotteryStatusTone(event.status),
                    solid: true,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.prizeName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppThemeStyle.of(context).title(TextStyle(
                    fontSize: 22,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    color: tokens.textPrimary,
                  )),
                ),
                const SizedBox(height: 4),
                Text(
                  '${event.title} · ${formatLotteryBeijing(event.drawTime, withYear: false)} 开奖（北京时间）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: tokens.textSecondary),
                ),
                const SizedBox(height: 14),
                if (event.isOngoing)
                  _LotteryCountdown(remaining: remaining)
                else
                  _LotteryResultStrip(event: event),
                const SizedBox(height: 14),
                Divider(height: 1, color: tokens.divider),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    children: [
                      _HeroStat(
                          icon: Icons.group_outlined,
                          label: '当前参与',
                          value: '$participantCount 人'),
                      VerticalDivider(width: 24, color: tokens.divider),
                      _HeroStat(
                          icon: Icons.trending_up_rounded,
                          label: '我的权重',
                          value: myWeight == null ? '—' : '$myWeight 份'),
                      VerticalDivider(width: 24, color: tokens.divider),
                      _HeroStat(
                          icon: Icons.verified_user_outlined,
                          label: '开奖方式',
                          value: event.drawMode == LotteryDrawMode.manual
                              ? '手动补开'
                              : '自动摇号'),
                    ],
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

/// 与服务端 draw_mode 取值一致。
abstract final class LotteryDrawMode {
  static const manual = 'manual';
}

class _HeroStat extends StatelessWidget {
  const _HeroStat(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: tokens.primary),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12, color: tokens.textSecondary)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: tokens.textPrimary)),
        ],
      ),
    );
  }
}

class _LotteryCountdown extends StatelessWidget {
  const _LotteryCountdown({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final radius = AppShape.of(context).md;
    final label = Text('距离开奖',
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: tokens.textSecondary));
    if (remaining <= Duration.zero) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label,
          const SizedBox(height: 8),
          Container(
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.primaryContainer,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Text('已截止，等待系统开奖',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: tokens.onPrimaryContainer)),
          ),
        ],
      );
    }
    final parts = [
      (remaining.inDays, '天'),
      (remaining.inHours % 24, '时'),
      (remaining.inMinutes % 60, '分'),
      (remaining.inSeconds % 60, '秒'),
    ];
    return Semantics(
      label: '距离开奖 ${parts.map((p) => '${p.$1}${p.$2}').join()}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label,
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < parts.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 50,
                    decoration: BoxDecoration(
                      color: tokens.primaryContainer,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                    alignment: Alignment.center,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: parts[i].$1.toString().padLeft(2, '0'),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          TextSpan(
                            text: ' ${parts[i].$2}',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ]),
                        style: TextStyle(color: tokens.onPrimaryContainer),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LotteryResultStrip extends StatelessWidget {
  const _LotteryResultStrip({required this.event});

  final LotteryEvent event;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final winner = event.winner;
    final drawnAt = event.drawnAt ?? event.drawTime;
    final String title;
    final String subtitle;
    if (event.isDrawn && winner != null) {
      title = winner.nickname;
      subtitle = '${formatLotteryBeijing(drawnAt, withYear: false)} 按权重摇号产生';
    } else if (event.isDrawn) {
      title = '中奖用户已注销';
      subtitle = '${formatLotteryBeijing(drawnAt, withYear: false)} 已开奖';
    } else if (event.isNoWinner) {
      title = '本期已流拍';
      subtitle = '没有有效参与者';
    } else {
      title = event.isCancelled ? '本期活动已取消' : '本期已结束';
      subtitle = '感谢关注，留意下一期活动';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.primaryContainer,
        borderRadius: BorderRadius.circular(AppShape.of(context).md),
      ),
      child: Row(
        children: [
          if (winner != null)
            CachedAvatar(
              radius: 20,
              imageUrl: winner.avatar.isNotEmpty
                  ? ApiConstants.fullUrl(winner.avatar)
                  : null,
              fallbackText: winner.nickname,
            )
          else
            Icon(Icons.hourglass_disabled_rounded,
                size: 32, color: tokens.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: tokens.onPrimaryContainer)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            tokens.onPrimaryContainer.withValues(alpha: 0.75))),
              ],
            ),
          ),
          if (winner != null)
            const LotteryStatusChip(
                label: '恭喜中奖', tone: LotteryTone.warning, dot: false),
        ],
      ),
    );
  }
}

/// 活动说明：自动拆分编号条目，默认显示前 [collapsedItems] 条，可展开。
class LotteryDescriptionCard extends StatefulWidget {
  const LotteryDescriptionCard({
    super.key,
    required this.description,
    this.collapsedItems = 2,
  });

  final String description;
  final int collapsedItems;

  @override
  State<LotteryDescriptionCard> createState() => _LotteryDescriptionCardState();
}

class _LotteryDescriptionCardState extends State<LotteryDescriptionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final parsed = parseLotteryDescription(widget.description);
    final body =
        TextStyle(fontSize: 13.5, height: 1.6, color: tokens.textSecondary);
    final collapsible = parsed.items.length > widget.collapsedItems ||
        (parsed.items.isEmpty && parsed.lead.length > 120);
    final showAll = _expanded || !collapsible;
    final items = showAll
        ? parsed.items
        : parsed.items.take(widget.collapsedItems).toList();

    return LotteryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LotterySectionTitle('活动说明'),
          const SizedBox(height: 10),
          if (parsed.lead.isNotEmpty && (showAll || parsed.items.isEmpty))
            Padding(
              padding: EdgeInsets.only(bottom: parsed.items.isEmpty ? 0 : 6),
              child: Text(
                parsed.lead,
                maxLines: showAll ? null : 4,
                overflow: showAll ? null : TextOverflow.ellipsis,
                style: body,
              ),
            ),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    child: Text('${i + 1}.',
                        style: body.copyWith(
                            color: tokens.primary,
                            fontWeight: FontWeight.w700)),
                  ),
                  Expanded(child: Text(items[i], style: body)),
                ],
              ),
            ),
          if (collapsible)
            Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                iconAlignment: IconAlignment.end,
                icon: Icon(_expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded),
                label: Text(_expanded
                    ? '收起'
                    : parsed.items.isEmpty
                        ? '展开全文'
                        : '展开全部 ${parsed.items.length} 条'),
              ),
            ),
        ],
      ),
    );
  }
}
