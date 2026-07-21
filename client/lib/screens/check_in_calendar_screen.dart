import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';

class CheckInCalendarScreen extends StatefulWidget {
  final DateTime Function()? now;
  final bool autoCheckIn;

  const CheckInCalendarScreen({
    super.key,
    this.now,
    this.autoCheckIn = false,
  });

  @override
  State<CheckInCalendarScreen> createState() => _CheckInCalendarScreenState();
}

enum _CalendarDaySelection {
  signed,
  makeup,
  noMakeupCard,
  outsideMonth,
  future,
  today,
}

class _CheckInMonthSnapshot {
  final Map<DateTime, CheckInDayRecord> records;
  final int longestStreak;

  const _CheckInMonthSnapshot({
    required this.records,
    required this.longestStreak,
  });
}

class _CheckInCalendarScreenState extends State<CheckInCalendarScreen> {
  late DateTime _visibleMonth;
  final Map<String, _CheckInMonthSnapshot> _monthCache = {};
  final Map<String, Future<_CheckInMonthSnapshot>> _monthRequests = {};
  Map<DateTime, CheckInDayRecord> _records = const {};
  bool _loading = true;
  bool _checkingIn = false;
  bool _makingUp = false;
  bool _checkedInToday = false;
  int _streakDays = 0;
  int _longestStreak = 0;
  int _nextExp = 1;
  int _makeupCards = 0;
  String? _errorMessage;
  DateTime? _serverToday;
  DateTime? _selectedDate;
  _CalendarDaySelection? _selectedDaySelection;
  bool _autoCheckInAttempted = false;
  int _monthTransitionDirection = 0;

  DateTime get _deviceToday {
    final now = widget.now?.call() ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _today => _serverToday ?? _deviceToday;

  DateTime? get _selectedMakeupDate =>
      _selectedDaySelection == _CalendarDaySelection.makeup
          ? _selectedDate
          : null;

  bool get _isCurrentMonth =>
      _visibleMonth.year == _today.year && _visibleMonth.month == _today.month;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(_deviceToday.year, _deviceToday.month);
    _loadData();
  }

  Future<void> _loadData({
    bool showLoading = true,
    bool forceRefresh = false,
  }) async {
    final requestedMonth = _visibleMonth;
    final monthKey = _formatMonth(requestedMonth);
    final cachedMonth = _monthCache[monthKey];
    final followsDeviceMonth =
        _serverToday == null && _sameMonth(requestedMonth, _deviceToday);
    if (!forceRefresh && _serverToday != null && cachedMonth != null) {
      setState(() {
        _records = cachedMonth.records;
        _longestStreak = cachedMonth.longestStreak;
        _loading = false;
        _errorMessage = null;
      });
      _prefetchAround(requestedMonth);
      return;
    }
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    final auth = context.read<AuthProvider>();
    try {
      final shouldLoadStatus = _serverToday == null || forceRefresh;
      final Future<Response<dynamic>?> statusRequest = shouldLoadStatus
          ? auth.dio.get('/user/checkin/status')
          : Future<Response<dynamic>?>.value(null);
      final monthRequest = _loadMonthSnapshot(
        auth.dio,
        requestedMonth,
        forceRefresh: forceRefresh,
      );
      final statusResponse = await statusRequest;
      final monthSnapshot = await monthRequest;
      if (!mounted || requestedMonth != _visibleMonth) return;

      final status = statusResponse?.data is Map
          ? Map<String, dynamic>.from(statusResponse!.data as Map)
          : null;
      final serverToday = _parseDateOnly(status?['check_in_date']) ?? _today;
      if (followsDeviceMonth && !_sameMonth(requestedMonth, serverToday)) {
        setState(() {
          _serverToday = serverToday;
          _visibleMonth = DateTime(serverToday.year, serverToday.month);
          _checkedInToday = status?['checked_in'] == true;
          _streakDays = _readInt(status?['streak_days']);
          _nextExp = _readInt(status?['next_exp'], fallback: 1);
          _makeupCards = _readInt(status?['makeup_cards']);
          _records = const {};
        });
        await _loadData();
        return;
      }

      setState(() {
        _serverToday = serverToday;
        if (status != null) {
          _checkedInToday = status['checked_in'] == true;
          _streakDays = _readInt(status['streak_days']);
          _nextExp = _readInt(status['next_exp'], fallback: 1);
          _makeupCards = _readInt(status['makeup_cards']);
        }
        _longestStreak = monthSnapshot.longestStreak;
        _records = monthSnapshot.records;
        if (_selectedMakeupDate != null &&
            monthSnapshot.records.containsKey(_selectedMakeupDate)) {
          _selectedDate = null;
          _selectedDaySelection = null;
        }
        _loading = false;
        _errorMessage = null;
      });
      _prefetchAround(requestedMonth);
      _maybeAutoCheckIn();
    } on DioException catch (error) {
      if (!mounted || requestedMonth != _visibleMonth) return;
      _handleLoadError(
        requestedMonth,
        AppFeedback.dioErrorMessage(
          error,
          fallback: '签到记录加载失败，请稍后重试',
        ),
      );
    } catch (_) {
      if (!mounted || requestedMonth != _visibleMonth) return;
      _handleLoadError(requestedMonth, '签到记录加载失败，请稍后重试');
    }
  }

  Future<_CheckInMonthSnapshot> _loadMonthSnapshot(
    Dio dio,
    DateTime month, {
    bool forceRefresh = false,
  }) async {
    final key = _formatMonth(month);
    if (!forceRefresh) {
      final cached = _monthCache[key];
      if (cached != null) return cached;
      final activeRequest = _monthRequests[key];
      if (activeRequest != null) return activeRequest;
    }

    final request = _requestMonthSnapshot(dio, month);
    _monthRequests[key] = request;
    try {
      final snapshot = await request;
      _monthCache[key] = snapshot;
      return snapshot;
    } finally {
      if (identical(_monthRequests[key], request)) {
        _monthRequests.remove(key);
      }
    }
  }

  Future<_CheckInMonthSnapshot> _requestMonthSnapshot(
    Dio dio,
    DateTime month,
  ) async {
    final response = await dio.get(
      '/user/checkin/calendar',
      queryParameters: {'month': _formatMonth(month)},
    );
    final calendar = Map<String, dynamic>.from(response.data as Map);
    final rawRecords = calendar['records'] as List<dynamic>? ?? const [];
    final records = <DateTime, CheckInDayRecord>{};
    for (final raw in rawRecords) {
      final record = CheckInDayRecord.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      records[record.date] = record;
    }
    return _CheckInMonthSnapshot(
      records: records,
      longestStreak: _readInt(calendar['longest_streak']),
    );
  }

  void _prefetchAround(DateTime month) {
    if (!mounted) return;
    final dio = context.read<AuthProvider>().dio;
    for (final offset in const [-1, -2, 1]) {
      final target = DateTime(month.year, month.month + offset);
      if (_isMonthAfter(target, _today)) continue;
      unawaited(
        _loadMonthSnapshot(dio, target).catchError(
          (_) => _CheckInMonthSnapshot(
            records: const {},
            longestStreak: _longestStreak,
          ),
        ),
      );
    }
  }

  void _handleLoadError(DateTime requestedMonth, String message) {
    final cached = _monthCache[_formatMonth(requestedMonth)];
    setState(() {
      _loading = false;
      if (cached != null) {
        _records = cached.records;
        _longestStreak = cached.longestStreak;
        _errorMessage = null;
      } else {
        _errorMessage = message;
      }
    });
    if (cached != null) {
      AppFeedback.showSnackBar(context, message, isError: true);
    }
  }

  void _maybeAutoCheckIn() {
    if (!widget.autoCheckIn ||
        _autoCheckInAttempted ||
        _checkedInToday ||
        _loading) {
      return;
    }
    _autoCheckInAttempted = true;
    unawaited(_doCheckIn());
  }

  Future<void> _changeMonth(int offset) async {
    if (_loading || (offset > 0 && _isCurrentMonth)) return;
    final next = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + offset,
    );
    final cached = _monthCache[_formatMonth(next)];
    setState(() {
      _monthTransitionDirection = offset;
      _visibleMonth = next;
      _records = cached?.records ?? const {};
      _longestStreak = cached?.longestStreak ?? _longestStreak;
      _loading = cached == null;
      _errorMessage = null;
      _selectedDate = null;
      _selectedDaySelection = null;
    });
    await _loadData(showLoading: cached == null);
  }

  void _handleMonthSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 250) return;
    _changeMonth(velocity > 0 ? -1 : 1);
  }

  void _selectCalendarDay(
    DateTime date,
    _CalendarDaySelection selection,
  ) {
    setState(() {
      if (_selectedDate == date) {
        _selectedDate = null;
        _selectedDaySelection = null;
      } else {
        _selectedDate = date;
        _selectedDaySelection = selection;
      }
    });
  }

  void _handleCalendarDayTap(
    DateTime date,
    CheckInDayRecord? record,
  ) {
    if (record != null) {
      _selectCalendarDay(date, _CalendarDaySelection.signed);
      return;
    }
    if (!_sameMonth(date, _today)) {
      _selectCalendarDay(date, _CalendarDaySelection.outsideMonth);
      return;
    }
    if (date == _today) {
      _selectCalendarDay(date, _CalendarDaySelection.today);
      return;
    }
    if (date.isAfter(_today)) {
      _selectCalendarDay(date, _CalendarDaySelection.future);
      return;
    }
    _selectCalendarDay(
      date,
      _makeupCards > 0
          ? _CalendarDaySelection.makeup
          : _CalendarDaySelection.noMakeupCard,
    );
  }

  Future<void> _doMakeup() async {
    final date = _selectedMakeupDate;
    if (date == null || _makingUp || _makeupCards <= 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        return AlertDialog(
          title: const Text('使用补签卡'),
          content: Text(
            '确定补签 ${date.month} 月 ${date.day} 日吗？\n将消耗 1 张补签卡，并按连续签到规则补发经验。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor:
                    isDark ? const Color(0xFF707070) : const Color(0xFF363636),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认补签'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _makingUp = true);
    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.post(
        '/user/checkin/makeup',
        data: {'check_in_date': _formatDate(date)},
      );
      if (!mounted || response.statusCode != 200) return;
      final data = Map<String, dynamic>.from(response.data as Map);
      final already = data['already'] == true;
      final earnedExp = _readInt(data['exp_earned']);
      final cardsAwarded = _readInt(data['makeup_cards_awarded']);
      setState(() {
        _makeupCards = _readInt(data['makeup_cards']);
        _selectedDate = null;
        _selectedDaySelection = null;
      });
      await _loadData(showLoading: false, forceRefresh: true);
      unawaited(auth.refreshUser());
      if (!mounted) return;
      if (already) {
        AppFeedback.showSnackBar(context, '该日期已经签到');
      } else {
        HapticFeedback.lightImpact();
        final cardMessage = cardsAwarded > 0 ? '，获得补签卡 +$cardsAwarded' : '';
        AppFeedback.showSnackBar(
          context,
          '补签成功，经验 +$earnedExp$cardMessage',
        );
      }
    } on DioException catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(error, fallback: '补签失败，请稍后再试'),
        isError: true,
      );
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '补签失败，请稍后再试', isError: true);
    } finally {
      if (mounted) setState(() => _makingUp = false);
    }
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
      await _loadData(showLoading: false, forceRefresh: true);
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

  Widget _buildMonthContent() {
    final Widget content;
    final String stateKey;
    if (_loading) {
      stateKey = 'loading';
      content = const SizedBox(
        height: 360,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_errorMessage != null) {
      stateKey = 'error';
      content = _CalendarError(
        message: _errorMessage!,
        onRetry: _loadData,
      );
    } else {
      stateKey = 'ready';
      content = CheckInMonthCalendar(
        month: _visibleMonth,
        today: _today,
        records: _records,
        selectedDate: _selectedDate,
        onDayTap: _handleCalendarDayTap,
      );
    }
    final beginX = _monthTransitionDirection == 0
        ? 0.0
        : (_monthTransitionDirection > 0 ? 0.06 : -0.06);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(beginX, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey('${_formatMonth(_visibleMonth)}-$stateKey'),
          child: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = _selectedDaySelection;
    final selectedDateText = _selectedDate == null
        ? ''
        : '${_selectedDate!.month} 月 ${_selectedDate!.day} 日';
    final blocksAction = selection == _CalendarDaySelection.signed ||
        selection == _CalendarDaySelection.noMakeupCard ||
        selection == _CalendarDaySelection.outsideMonth ||
        selection == _CalendarDaySelection.future;
    final VoidCallback? actionOnPressed;
    if (selection == _CalendarDaySelection.makeup) {
      actionOnPressed = _makingUp || _makeupCards <= 0 ? null : _doMakeup;
    } else if (blocksAction) {
      actionOnPressed = null;
    } else {
      actionOnPressed = _checkedInToday || _checkingIn ? null : _doCheckIn;
    }
    final actionIcon = switch (selection) {
      _CalendarDaySelection.makeup => Icons.event_repeat_rounded,
      _CalendarDaySelection.signed => Icons.check_circle_rounded,
      _CalendarDaySelection.noMakeupCard => Icons.confirmation_number_outlined,
      _CalendarDaySelection.outsideMonth ||
      _CalendarDaySelection.future =>
        Icons.event_busy_rounded,
      _CalendarDaySelection.today ||
      null =>
        _checkedInToday ? Icons.check_circle_rounded : Icons.task_alt_rounded,
    };
    final actionLabel = _makingUp
        ? '补签中'
        : _checkingIn
            ? '签到中'
            : switch (selection) {
                _CalendarDaySelection.makeup => '使用补签卡补签 $selectedDateText',
                _CalendarDaySelection.signed => '$selectedDateText已签到',
                _CalendarDaySelection.noMakeupCard => '暂无补签卡',
                _CalendarDaySelection.outsideMonth => '非本月日期不可补签',
                _CalendarDaySelection.future => '未来日期不可补签',
                _CalendarDaySelection.today ||
                null =>
                  _checkedInToday ? '今日已签到' : '签到领取 $_nextExp 经验',
              };
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '签到日历',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadData(
          showLoading: false,
          forceRefresh: true,
        ),
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
                          makeupCards: _makeupCards,
                        ),
                        const SizedBox(height: 20),
                        GestureDetector(
                          key: const ValueKey('check-in-month-swipe-area'),
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragEnd: _handleMonthSwipe,
                          child: Column(
                            children: [
                              _MonthHeader(
                                month: _visibleMonth,
                                canGoNext: !_isCurrentMonth,
                                onPrevious: () => _changeMonth(-1),
                                onNext: () => _changeMonth(1),
                              ),
                              const SizedBox(height: 10),
                              _buildMonthContent(),
                              const SizedBox(height: 16),
                              _CalendarLegend(theme: theme),
                            ],
                          ),
                        ),
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
                child: _CheckInActionButton(
                  onPressed: actionOnPressed,
                  icon: _checkingIn || _makingUp
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(actionIcon),
                  label: actionLabel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckInActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget icon;
  final String label;

  const _CheckInActionButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = enabled
        ? (isDark
            ? const [Color(0xFF747474), Color(0xFF383838)]
            : const [Color(0xFF666666), Color(0xFF292929)])
        : (isDark
            ? const [Color(0xFF333333), Color(0xFF292929)]
            : const [Color(0xFFE2E2E2), Color(0xFFD5D5D5)]);
    final disabledForeground =
        isDark ? const Color(0xFF898989) : const Color(0xFF8E8E8E);

    return DecoratedBox(
      key: const ValueKey('check-in-primary-action-gradient'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          disabledForegroundColor: disabledForeground,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const StadiumBorder(),
        ),
        onPressed: onPressed,
        icon: icon,
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
  final int makeupCards;

  const _CheckInSummary({
    required this.checkedInToday,
    required this.streakDays,
    required this.longestStreak,
    required this.monthCount,
    required this.nextExp,
    required this.makeupCards,
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
              const SizedBox(width: 12),
              Semantics(
                label: '补签卡 $makeupCards 张',
                excludeSemantics: true,
                child: Column(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.confirmation_number_outlined,
                          size: 18,
                          color: foreground.withValues(alpha: 0.72),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$makeupCards',
                          style: TextStyle(
                            color: foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '补签卡',
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.58),
                        fontSize: 10.5,
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: Text(
              '${month.year}年${month.month}月',
              key: ValueKey(_formatMonth(month)),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
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

typedef CheckInCalendarDayTap = void Function(
  DateTime date,
  CheckInDayRecord? record,
);

class CheckInMonthCalendar extends StatelessWidget {
  final DateTime month;
  final DateTime today;
  final Map<DateTime, CheckInDayRecord> records;
  final DateTime? selectedDate;
  final CheckInCalendarDayTap? onDayTap;

  const CheckInMonthCalendar({
    super.key,
    required this.month,
    required this.today,
    required this.records,
    this.selectedDate,
    this.onDayTap,
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
              final record = records[date];
              return _CalendarDay(
                date: date,
                today: today,
                record: record,
                selected: date == selectedDate,
                onTap: onDayTap == null
                    ? null
                    : (tappedDate) => onDayTap!(tappedDate, record),
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
  final bool selected;
  final ValueChanged<DateTime>? onTap;

  const _CalendarDay({
    required this.date,
    required this.today,
    required this.record,
    required this.selected,
    required this.onTap,
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
    final dateState = isToday
        ? (isSigned ? '，今天，已签到' : '，今天')
        : isSigned
            ? (record!.isMakeup ? '，已补签' : '，已签到')
            : isMissed
                ? '，未签到'
                : '';
    final semanticsState = '$dateState${selected ? '，已选择' : ''}';

    return Semantics(
      label: '${date.month}月${date.day}日$semanticsState',
      button: onTap != null,
      excludeSemantics: true,
      child: Center(
        child: InkResponse(
          radius: 24,
          onTap: onTap == null ? null : () => onTap!(date),
          child: Container(
            key: ValueKey('check-in-day-${_formatDate(date)}'),
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fillColor,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(color: const Color(0xFF8F665F), width: 1.5)
                  : isToday
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
  final bool isMakeup;

  const CheckInDayRecord({
    required this.date,
    required this.streakDays,
    required this.expEarned,
    this.isMakeup = false,
  });

  factory CheckInDayRecord.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['check_in_date'] as String);
    return CheckInDayRecord(
      date: DateTime(date.year, date.month, date.day),
      streakDays: _readInt(json['streak_days']),
      expEarned: _readInt(json['exp_earned']),
      isMakeup: json['is_makeup'] == true,
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

bool _isMonthAfter(DateTime left, DateTime right) {
  return left.year > right.year ||
      (left.year == right.year && left.month > right.month);
}

String _formatMonth(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  return '${value.year}-$month';
}

String _formatDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}
