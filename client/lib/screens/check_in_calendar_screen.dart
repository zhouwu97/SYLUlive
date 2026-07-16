import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';

class CheckInCalendarScreen extends StatefulWidget {
  final DateTime Function()? now;

  const CheckInCalendarScreen({super.key, this.now});

  @override
  State<CheckInCalendarScreen> createState() => _CheckInCalendarScreenState();
}

class _CheckInCalendarScreenState extends State<CheckInCalendarScreen> {
  late DateTime _visibleMonth;
  Map<DateTime, CheckInDayRecord> _records = const {};
  bool _loading = true;
  bool _checkingIn = false;
  bool _checkedInToday = false;
  int _streakDays = 0;
  int _longestStreak = 0;
  int _nextExp = 1;
  String? _errorMessage;
  DateTime? _serverToday;

  DateTime get _deviceToday {
    final now = widget.now?.call() ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _today => _serverToday ?? _deviceToday;

  bool get _isCurrentMonth =>
      _visibleMonth.year == _today.year && _visibleMonth.month == _today.month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visibleMonth = DateTime(now.year, now.month);
    _loadData();
  }

  Future<void> _loadData({bool showLoading = true}) async {
    final requestedMonth = _visibleMonth;
    final followsDeviceMonth =
        _serverToday == null && _sameMonth(requestedMonth, _deviceToday);
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    final auth = context.read<AuthProvider>();
    try {
      final responses = await Future.wait([
        auth.dio.get('/user/checkin/status'),
        auth.dio.get(
          '/user/checkin/calendar',
          queryParameters: {'month': _formatMonth(requestedMonth)},
        ),
      ]);
      if (!mounted || requestedMonth != _visibleMonth) return;

      final status = Map<String, dynamic>.from(responses[0].data as Map);
      final calendar = Map<String, dynamic>.from(responses[1].data as Map);
      final serverToday = _parseDateOnly(status['check_in_date']) ?? _today;
      if (followsDeviceMonth && !_sameMonth(requestedMonth, serverToday)) {
        setState(() {
          _serverToday = serverToday;
          _visibleMonth = DateTime(serverToday.year, serverToday.month);
          _checkedInToday = status['checked_in'] == true;
          _streakDays = _readInt(status['streak_days']);
          _nextExp = _readInt(status['next_exp'], fallback: 1);
          _records = const {};
        });
        await _loadData();
        return;
      }
      final rawRecords = calendar['records'] as List<dynamic>? ?? const [];
      final records = <DateTime, CheckInDayRecord>{};
      for (final raw in rawRecords) {
        final record = CheckInDayRecord.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        records[record.date] = record;
      }

      setState(() {
        _serverToday = serverToday;
        _checkedInToday = status['checked_in'] == true;
        _streakDays = _readInt(status['streak_days']);
        _nextExp = _readInt(status['next_exp'], fallback: 1);
        _longestStreak = _readInt(calendar['longest_streak']);
        _records = records;
        _loading = false;
        _errorMessage = null;
      });
    } on DioException catch (error) {
      if (!mounted || requestedMonth != _visibleMonth) return;
      setState(() {
        _loading = false;
        _errorMessage = AppFeedback.dioErrorMessage(
          error,
          fallback: '签到记录加载失败，请稍后重试',
        );
      });
    } catch (_) {
      if (!mounted || requestedMonth != _visibleMonth) return;
      setState(() {
        _loading = false;
        _errorMessage = '签到记录加载失败，请稍后重试';
      });
    }
  }

  Future<void> _changeMonth(int offset) async {
    if (offset > 0 && _isCurrentMonth) return;
    final next = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + offset,
    );
    setState(() {
      _visibleMonth = next;
      _records = const {};
    });
    await _loadData();
  }

  Future<void> _doCheckIn() async {
    if (_checkingIn || _checkedInToday) return;
    setState(() => _checkingIn = true);
    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.post('/user/checkin');
      if (!mounted || response.statusCode != 200) return;

      final data = Map<String, dynamic>.from(response.data as Map);
      final already = data['already'] == true;
      final streak = _readInt(data['streak_days'], fallback: 1);
      final earnedExp = _readInt(data['exp_earned']);
      final serverToday = _parseDateOnly(data['check_in_date']) ?? _today;
      setState(() {
        _serverToday = serverToday;
        _visibleMonth = DateTime(serverToday.year, serverToday.month);
        _checkedInToday = true;
        _streakDays = streak;
      });
      await _loadData(showLoading: false);
      unawaited(auth.refreshUser());
      if (!mounted) return;

      if (already) {
        AppFeedback.showSnackBar(context, '今天已经签过到了');
      } else {
        HapticFeedback.lightImpact();
        await _showSuccessSheet(streak, earnedExp);
      }
    } on DioException catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '签到失败，请稍后再试'),
        isError: true,
      );
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '签到失败，请稍后再试', isError: true);
    } finally {
      if (mounted) setState(() => _checkingIn = false);
    }
  }

  Future<void> _showSuccessSheet(int streakDays, int earnedExp) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.task_alt_rounded,
                    color: Color(0xFF15803D),
                    size: 28,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '签到成功',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '连续 $streakDays 天 · 经验 +$earnedExp',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '签到日历',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadData(showLoading: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _CheckInSummary(
                          checkedInToday: _checkedInToday,
                          streakDays: _streakDays,
                          longestStreak: _longestStreak,
                          monthCount: _records.length,
                          nextExp: _nextExp,
                        ),
                        const SizedBox(height: 20),
                        _MonthHeader(
                          month: _visibleMonth,
                          canGoNext: !_isCurrentMonth,
                          onPrevious: () => _changeMonth(-1),
                          onNext: () => _changeMonth(1),
                        ),
                        const SizedBox(height: 10),
                        if (_loading)
                          const SizedBox(
                            height: 360,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_errorMessage != null)
                          _CalendarError(
                            message: _errorMessage!,
                            onRetry: _loadData,
                          )
                        else
                          CheckInMonthCalendar(
                            month: _visibleMonth,
                            today: _today,
                            records: _records,
                          ),
                        const SizedBox(height: 16),
                        _CalendarLegend(theme: theme),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 648),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _checkedInToday || _checkingIn ? null : _doCheckIn,
                  icon: _checkingIn
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _checkedInToday
                              ? Icons.check_circle_rounded
                              : Icons.task_alt_rounded,
                        ),
                  label: Text(
                    _checkingIn
                        ? '签到中'
                        : _checkedInToday
                            ? '今日已签到'
                            : '签到领取 $_nextExp 经验',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckInSummary extends StatelessWidget {
  final bool checkedInToday;
  final int streakDays;
  final int longestStreak;
  final int monthCount;
  final int nextExp;

  const _CheckInSummary({
    required this.checkedInToday,
    required this.streakDays,
    required this.longestStreak,
    required this.monthCount,
    required this.nextExp,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF29312C);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C211E) : const Color(0xFFF5F7F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF303630) : const Color(0xFFE3E7E3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF252B27) : Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  color: isDark
                      ? const Color(0xFF94A89A)
                      : const Color(0xFF607568),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      checkedInToday ? '今天已完成签到' : '今天还未签到',
                      style: TextStyle(
                        color: foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      checkedInToday
                          ? '明天继续可领取 $nextExp 经验'
                          : '签到后可领取 $nextExp 经验',
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.68),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(
            height: 1,
            color: foreground.withValues(alpha: 0.10),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SummaryMetric(
                  value: '$streakDays',
                  label: '当前连续',
                  foreground: foreground,
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  value: '$longestStreak',
                  label: '最长连续',
                  foreground: foreground,
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  value: '$monthCount',
                  label: '本月签到',
                  foreground: foreground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color foreground;

  const _SummaryMetric({
    required this.value,
    required this.label,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: foreground,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: foreground.withValues(alpha: 0.62),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime month;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _MonthHeader({
    required this.month,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: '上个月',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text(
            '${month.year}年${month.month}月',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          tooltip: '下个月',
          onPressed: canGoNext ? onNext : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class CheckInMonthCalendar extends StatelessWidget {
  final DateTime month;
  final DateTime today;
  final Map<DateTime, CheckInDayRecord> records;

  const CheckInMonthCalendar({
    super.key,
    required this.month,
    required this.today,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    const weekdayLabels = ['日', '一', '二', '三', '四', '五', '六'];
    final firstDay = DateTime(month.year, month.month, 1);
    final leadingEmptyDays = firstDay.weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            children: weekdayLabels
                .map(
                  (label) => Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.88,
            ),
            itemCount: 42,
            itemBuilder: (context, index) {
              final dayNumber = index - leadingEmptyDays + 1;
              if (dayNumber < 1 || dayNumber > daysInMonth) {
                return const SizedBox.shrink();
              }
              final date = DateTime(month.year, month.month, dayNumber);
              return _CalendarDay(
                date: date,
                today: today,
                record: records[date],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CalendarDay extends StatelessWidget {
  final DateTime date;
  final DateTime today;
  final CheckInDayRecord? record;

  const _CalendarDay({
    required this.date,
    required this.today,
    required this.record,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSigned = record != null;
    final isToday = date == today;
    final isFuture = date.isAfter(today);
    final isMissed = date.isBefore(today) && !isSigned;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = isSigned
        ? (isDark ? const Color(0xFF28332C) : const Color(0xFFEAF0EC))
        : isMissed
            ? (isDark ? const Color(0xFF342725) : const Color(0xFFF7F1F0))
            : Colors.transparent;
    final textColor = isSigned
        ? (isDark ? const Color(0xFFB7C8BC) : const Color(0xFF4E6858))
        : isMissed
            ? (isDark ? const Color(0xFFD0AAA4) : const Color(0xFF9A6B65))
            : isFuture
                ? scheme.onSurface.withValues(alpha: 0.25)
                : scheme.onSurface;
    final semanticsState = isToday
        ? (isSigned ? '，今天，已签到' : '，今天')
        : isSigned
            ? '，已签到'
            : isMissed
                ? '，未签到'
                : '';

    return Semantics(
      label: '${date.month}月${date.day}日$semanticsState',
      excludeSemantics: true,
      child: Center(
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fillColor,
            shape: BoxShape.circle,
            border: isToday
                ? Border.all(color: const Color(0xFF607568), width: 1.5)
                : null,
          ),
          child: isSigned || isMissed
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${date.day}',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        height: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Icon(
                      isSigned ? Icons.check_rounded : Icons.close_rounded,
                      size: 10,
                      color: isSigned
                          ? const Color(0xFF758D7D)
                          : const Color(0xFFB8867F),
                    ),
                  ],
                )
              : Text(
                  '${date.day}',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
        ),
      ),
    );
  }
}

class _CalendarLegend extends StatelessWidget {
  final ThemeData theme;

  const _CalendarLegend({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _LegendDot(
          color: Color(0xFFEAF0EC),
          borderColor: Color(0xFF758D7D),
          icon: Icons.check_rounded,
          iconColor: Color(0xFF758D7D),
        ),
        const SizedBox(width: 6),
        Text(
          '已签到',
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 16),
        const _LegendDot(
          color: Color(0xFFF7F1F0),
          borderColor: Color(0xFFB8867F),
          icon: Icons.close_rounded,
          iconColor: Color(0xFFB8867F),
        ),
        const SizedBox(width: 6),
        Text(
          '未签到',
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 16),
        const _LegendDot(
          color: Colors.transparent,
          borderColor: Color(0xFF607568),
        ),
        const SizedBox(width: 6),
        Text(
          '今天',
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final Color? borderColor;
  final IconData? icon;
  final Color? iconColor;

  const _LegendDot({
    required this.color,
    this.borderColor,
    this.icon,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: icon == null
          ? null
          : Icon(icon, size: 9, color: iconColor ?? borderColor),
    );
  }
}

class _CalendarError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _CalendarError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 360,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}

class CheckInDayRecord {
  final DateTime date;
  final int streakDays;
  final int expEarned;

  const CheckInDayRecord({
    required this.date,
    required this.streakDays,
    required this.expEarned,
  });

  factory CheckInDayRecord.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['check_in_date'] as String);
    return CheckInDayRecord(
      date: DateTime(date.year, date.month, date.day),
      streakDays: _readInt(json['streak_days']),
      expEarned: _readInt(json['exp_earned']),
    );
  }
}

int _readInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _parseDateOnly(dynamic value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

bool _sameMonth(DateTime left, DateTime right) {
  return left.year == right.year && left.month == right.month;
}

String _formatMonth(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  return '${value.year}-$month';
}
