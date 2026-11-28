import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/lottery.dart';
import '../providers/auth_provider.dart';
import '../services/async_action_guard.dart';
import '../services/idempotency_key.dart';
import '../services/publish_session_scope.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_page_background.dart';
import '../theme/app_theme_style.dart';
import '../theme/app_theme_tokens.dart';
import '../widgets/lottery/lottery_widgets.dart';

class LotteryScreen extends StatefulWidget {
  const LotteryScreen({super.key});

  @override
  State<LotteryScreen> createState() => _LotteryScreenState();
}

class _LotteryScreenState extends State<LotteryScreen> {
  bool _isLoading = true;
  bool _isEmpty = false;
  String? _errorMessage;
  LotteryEvent? _event;
  int _participantCount = 0;
  bool _joined = false;
  int _myWeight = 0;
  bool _academicConfigured = false;
  Duration _serverClockOffset = Duration.zero;

  List<LotteryEvent> _history = const [];
  bool _historyLoading = false;
  String? _historyError;
  int _historyRequestSeq = 0;

  bool _isSubmitting = false;
  bool _postDrawRefreshInFlight = false;
  DateTime? _lastPostDrawRefreshAt;

  String? _joinIdempotencyKey;
  int? _joinIdempotencyEventId;
  String? _drawIdempotencyKey;
  int? _drawIdempotencyEventId;

  final AsyncActionGuard _actionGuard = AsyncActionGuard();

  int _requestSeq = 0;
  int? _boundUserId;
  int? _boundSessionEpoch;

  late Dio _dio;
  Timer? _countdownTimer;

  DateTime _now() => DateTime.now().add(_serverClockOffset);

  bool _isDrawTimeReached(LotteryEvent event) =>
      !event.drawTime.isAfter(_now());

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _dio = auth.dio;
    _boundUserId = auth.user?.id;
    _boundSessionEpoch = auth.accountSessionEpoch;
    _academicConfigured = auth.user?.academicConfigured == true;
    _loadPage();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    final nextUserId = auth.user?.id;
    final nextEpoch = auth.accountSessionEpoch;
    if (nextUserId != _boundUserId || nextEpoch != _boundSessionEpoch) {
      _boundUserId = nextUserId;
      _boundSessionEpoch = nextEpoch;
      _dio = auth.dio;
      _isSubmitting = false;
      _isLoading = true;
      _event = null;
      _history = const [];
      _historyError = null;
      _historyRequestSeq++;
      _postDrawRefreshInFlight = false;
      _lastPostDrawRefreshAt = null;
      _serverClockOffset = Duration.zero;
      _countdownTimer?.cancel();
      _joinIdempotencyKey = null;
      _joinIdempotencyEventId = null;
      _drawIdempotencyKey = null;
      _drawIdempotencyEventId = null;
      _academicConfigured = auth.user?.academicConfigured == true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadPage();
      });
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  bool _isCurrentSession(int requestSeq, int? userId, int? epoch) {
    if (!mounted || requestSeq != _requestSeq) return false;
    final auth = context.read<AuthProvider>();
    return auth.user?.id == userId && auth.accountSessionEpoch == epoch;
  }

  bool _ownsAction(PublishSessionScope session, int eventId) {
    if (!mounted || _event?.id != eventId) return false;
    final auth = context.read<AuthProvider>();
    return session.owns(
        userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch);
  }

  Future<void> _loadPage({bool silent = false}) async {
    await Future.wait([
      _fetchLottery(silent: silent),
      _fetchHistory(),
    ]);
  }

  Future<void> _fetchLottery({bool silent = false}) async {
    final requestSeq = ++_requestSeq;
    final userId = _boundUserId;
    final epoch = _boundSessionEpoch;

    if (mounted && !silent) {
      setState(() {
        _isLoading = true;
        _isEmpty = false;
        _errorMessage = null;
      });
    }
    try {
      final response = await _dio.get('/lottery/current');
      if (!mounted || !_isCurrentSession(requestSeq, userId, epoch)) return;
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : const <String, dynamic>{};
      final rawEvent = data['event'];
      if (rawEvent is! Map) {
        setState(() {
          _event = null;
          _isSubmitting = false;
          _isEmpty = true;
          _isLoading = false;
          _errorMessage = null;
        });
        _countdownTimer?.cancel();
        return;
      }

      final event = LotteryEvent.fromJson(Map<String, dynamic>.from(rawEvent));
      final serverTimeRaw = data['server_time']?.toString();
      if (serverTimeRaw != null && serverTimeRaw.isNotEmpty) {
        final serverTime = DateTime.tryParse(serverTimeRaw);
        if (serverTime != null) {
          _serverClockOffset = serverTime.difference(DateTime.now());
        }
      }

      if (_joinIdempotencyEventId != event.id) {
        _joinIdempotencyKey = null;
        _joinIdempotencyEventId = null;
      }
      if (_drawIdempotencyEventId != event.id) {
        _drawIdempotencyKey = null;
        _drawIdempotencyEventId = null;
      }

      final authAcademic =
          context.read<AuthProvider>().user?.academicConfigured == true;
      setState(() {
        if (_event?.id != event.id) _isSubmitting = false;
        _event = event;
        _participantCount = (data['participant_count'] as num?)?.toInt() ??
            event.participantCount;
        _joined = data['joined'] == true;
        _myWeight = (data['my_weight'] as num?)?.toInt() ?? 0;
        _academicConfigured = data.containsKey('academic_configured')
            ? data['academic_configured'] == true
            : authAcademic;
        _isLoading = false;
        _isEmpty = false;
        _errorMessage = null;
      });

      if (event.isOngoing) {
        if (!_isDrawTimeReached(event)) {
          _lastPostDrawRefreshAt = null;
        }
        _startCountdown();
      } else {
        _countdownTimer?.cancel();
      }
    } on DioException catch (e) {
      if (!_isCurrentSession(requestSeq, userId, epoch)) return;
      if (e.response?.statusCode == 404) {
        _countdownTimer?.cancel();
        setState(() {
          _event = null;
          _isLoading = false;
          _isEmpty = true;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _isLoading = false;
          _isEmpty = false;
          _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
        });
      }
    } catch (_) {
      if (!_isCurrentSession(requestSeq, userId, epoch)) return;
      setState(() {
        _isLoading = false;
        _isEmpty = false;
        _errorMessage = '发生未知错误';
      });
    }
  }

  Future<void> _fetchHistory() async {
    final requestSeq = ++_historyRequestSeq;
    final userId = _boundUserId;
    final epoch = _boundSessionEpoch;
    bool current() {
      if (!mounted || requestSeq != _historyRequestSeq) return false;
      final auth = context.read<AuthProvider>();
      return auth.user?.id == userId && auth.accountSessionEpoch == epoch;
    }

    if (mounted) {
      setState(() {
        _historyLoading = true;
        _historyError = null;
      });
    }
    try {
      final response = await _dio.get(
        '/lottery/history',
        queryParameters: const {'page': 1, 'page_size': 10},
      );
      if (!current()) return;
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : const <String, dynamic>{};
      final rawItems = data['items'];
      final list = rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) =>
                  LotteryEvent.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const <LotteryEvent>[];
      setState(() {
        _history = list;
        _historyLoading = false;
      });
    } catch (error) {
      if (!current()) return;
      setState(() {
        _historyLoading = false;
        _historyError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '加载往期抽奖失败')
            : '加载往期抽奖失败';
      });
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _refreshAfterDrawTimeIfNeeded();
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _refreshAfterDrawTimeIfNeeded() {
    final event = _event;
    if (event == null || !event.isOngoing || !_isDrawTimeReached(event)) {
      return;
    }

    final now = DateTime.now();
    if (_postDrawRefreshInFlight) return;
    if (_lastPostDrawRefreshAt != null &&
        now.difference(_lastPostDrawRefreshAt!) < const Duration(seconds: 15)) {
      return;
    }

    _lastPostDrawRefreshAt = now;
    _postDrawRefreshInFlight = true;
    final userId = _boundUserId;
    final epoch = _boundSessionEpoch;
    _loadPage(silent: true).whenComplete(() {
      if (_boundUserId == userId && _boundSessionEpoch == epoch) {
        _postDrawRefreshInFlight = false;
      }
    });
  }

  Future<void> _joinLottery() async {
    final event = _event;
    if (event == null || _isSubmitting) return;
    if (!event.isOngoing || _isDrawTimeReached(event)) {
      AppFeedback.showSnackBar(context, '该抽奖已截止参与，等待系统开奖', isError: true);
      return;
    }
    if (!_academicConfigured) {
      AppFeedback.showSnackBar(
        context,
        '请先完成教务连接并同步课表配置后再参与抽奖',
        isError: true,
      );
      return;
    }
    final eventId = event.id;
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id;
    if (userId == null) return;
    final session = PublishSessionScope(
        accountId: userId, accountSessionEpoch: auth.accountSessionEpoch);
    await _actionGuard.run<void>(
      'lottery-join:$userId:${session.accountSessionEpoch}:$eventId',
      () => _joinLotteryOnce(eventId, session),
    );
  }

  Future<void> _joinLotteryOnce(
      int eventId, PublishSessionScope session) async {
    if (mounted) setState(() => _isSubmitting = true);
    if (_joinIdempotencyEventId != eventId || _joinIdempotencyKey == null) {
      _joinIdempotencyEventId = eventId;
      _joinIdempotencyKey = newIdempotencyKey('lottery-join');
    }
    try {
      final response = await _dio.post(
        '/lottery/$eventId/join',
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _joinIdempotencyKey!,
        }, extra: session.requestExtra),
      );
      if (!mounted || !_ownsAction(session, eventId)) return;
      AppFeedback.showSnackBar(context, '参与成功！');
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : const <String, dynamic>{};
      setState(() {
        _joined = true;
        _myWeight = (data['weight'] as num?)?.toInt() ?? _myWeight;
        _participantCount++;
      });
      _joinIdempotencyKey = null;
      _joinIdempotencyEventId = null;
    } on DioException catch (e) {
      if (!mounted || !_ownsAction(session, eventId)) return;
      final status = e.response?.statusCode;
      // 后端返回 4xx/5xx 响应后释放旧键，避免 5xx 失败占位锁死后续重试。
      if (status != null) {
        _joinIdempotencyKey = null;
        _joinIdempotencyEventId = null;
      }
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '参与失败'),
        isError: true,
      );
    } finally {
      if (_ownsAction(session, eventId)) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _adminDraw() async {
    final event = _event;
    if (event == null || _isSubmitting) return;
    if (!event.isOngoing || !_isDrawTimeReached(event)) {
      AppFeedback.showSnackBar(context, '还未到开奖时间，无法手动补开', isError: true);
      return;
    }
    final auth = context.read<AuthProvider>();
    final userId = auth.user?.id;
    if (userId == null) return;
    final session = PublishSessionScope(
        accountId: userId, accountSessionEpoch: auth.accountSessionEpoch);
    final confirm = await AppFeedback.confirmDanger(
      context,
      title: '兜底手动补开',
      confirmText: '确认开奖',
      message: '当前已过开奖时间且系统尚未开奖，确定手动触发本次开奖吗？此操作不可逆。',
    );
    if (!confirm || !_ownsAction(session, event.id)) return;
    final eventId = event.id;
    await _actionGuard.run<void>(
      'lottery-draw:$userId:${session.accountSessionEpoch}:$eventId',
      () => _adminDrawOnce(eventId, session),
    );
  }

  Future<void> _adminDrawOnce(int eventId, PublishSessionScope session) async {
    if (mounted) setState(() => _isSubmitting = true);
    if (_drawIdempotencyEventId != eventId || _drawIdempotencyKey == null) {
      _drawIdempotencyEventId = eventId;
      _drawIdempotencyKey = newIdempotencyKey('lottery-draw');
    }
    try {
      await _dio.post(
        '/admin/lottery/$eventId/draw',
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _drawIdempotencyKey!,
        }, extra: session.requestExtra),
      );
      if (!mounted || !_ownsAction(session, eventId)) return;
      AppFeedback.showSnackBar(context, '开奖成功！');
      _drawIdempotencyKey = null;
      _drawIdempotencyEventId = null;
      await _loadPage(silent: true);
    } on DioException catch (e) {
      if (!mounted || !_ownsAction(session, eventId)) return;
      if (e.response?.statusCode != null) {
        _drawIdempotencyKey = null;
        _drawIdempotencyEventId = null;
      }
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '开奖失败'),
        isError: true,
      );
    } finally {
      if (_ownsAction(session, eventId)) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      AppPageBackground(builder: _buildPageWithBackground);

  Widget _buildPageWithBackground(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final isDark = tokens.isDark;
    final user = context.watch<AuthProvider>().user;
    final isSuperAdmin = user?.isSuperAdmin == true;
    final event = _event;
    final showBottom = !_isLoading &&
        _errorMessage == null &&
        !_isEmpty &&
        event != null &&
        event.isOngoing;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPageBackground.color(context, tokens.background),
        appBar: AppBar(
          title:
              const Text('官方抽奖', style: TextStyle(fontWeight: FontWeight.bold)),
          elevation: 0,
          backgroundColor: AppPageBackground.color(context, Colors.transparent),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _isLoading ? null : () => _loadPage(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        bottomNavigationBar: showBottom ? _buildBottomAction(event) : null,
        body: SafeArea(
          top: false,
          bottom: !showBottom,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
                  ? _buildErrorState()
                  : _isEmpty || event == null
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          onRefresh: () => _loadPage(silent: true),
                          child: _buildEventContent(event, isSuperAdmin),
                        ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final tokens = AppThemeTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ThemeStateArt(
              error: true,
              fallback: Icon(Icons.cloud_off_rounded,
                  size: 64, color: tokens.textTertiary),
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: tokens.textSecondary),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _loadPage(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final tokens = AppThemeTokens.of(context);
    return RefreshIndicator(
      onRefresh: () => _loadPage(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
        children: [
          Center(
            child: ThemeStateArt(
              fallback: Icon(Icons.inbox_rounded,
                  size: 72, color: tokens.textTertiary),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '暂无抽奖活动',
              style: TextStyle(fontSize: 16, color: tokens.textSecondary),
            ),
          ),
          const SizedBox(height: 28),
          _buildHistorySection(),
        ],
      ),
    );
  }

  Widget _buildEventContent(LotteryEvent ev, bool isSuperAdmin) {
    final drawTimeReached = _isDrawTimeReached(ev);
    final (warnFg, warnBg) = lotteryToneColors(context, LotteryTone.warning);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LotteryHeroCard(
            event: ev,
            participantCount: _participantCount,
            remaining: ev.drawTime.difference(_now()),
            myWeight: ev.isOngoing && _joined ? _myWeight : null,
          ),
          if (ev.description.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            LotteryDescriptionCard(description: ev.description),
          ],
          if (ev.isOngoing) ...[
            const SizedBox(height: 16),
            _buildLotteryRules(),
          ],
          // 仅到点后仍未开奖时，给超级管理员提供兜底手动补开入口。
          if (isSuperAdmin && ev.isOngoing && drawTimeReached) ...[
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: _isSubmitting ? null : _adminDraw,
                icon: const Icon(Icons.flash_on_rounded),
                label: const Text('兜底手动补开'),
                style: TextButton.styleFrom(
                  foregroundColor: warnFg,
                  backgroundColor: warnBg,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _buildHistorySection(),
        ],
      ),
    );
  }

  /// 进行中时固定在底部：未参与显示参与按钮，已参与显示当前权重。
  Widget _buildBottomAction(LotteryEvent ev) {
    final tokens = AppThemeTokens.of(context);
    final drawTimeReached = _isDrawTimeReached(ev);
    final Widget child;
    if (_joined) {
      final (fg, bg) = lotteryToneColors(context, LotteryTone.success);
      child = Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: fg.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: fg,
              child: Icon(Icons.check_rounded, size: 17, color: bg),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('已成功参与',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
                  Text('开奖时按最新等级计算权重',
                      style: TextStyle(
                          fontSize: 11.5, color: tokens.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Semantics(
                label: '当前权重 $_myWeight 份',
                excludeSemantics: true,
                child: Text('×$_myWeight',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800, color: fg)),
              ),
            ),
          ],
        ),
      );
    } else {
      final canJoin = !drawTimeReached && _academicConfigured && !_isSubmitting;
      final buttonText = drawTimeReached
          ? '已截止，等待系统开奖'
          : !_academicConfigured
              ? '需先连接教务后参与'
              : '立即参与';
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_academicConfigured && !drawTimeReached) ...[
            Text(
              '参与官方抽奖需先完成教务连接并同步课表配置',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: tokens.textSecondary),
            ),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton(
              onPressed: canJoin ? _joinLottery : null,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
              ),
              child: _isSubmitting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: tokens.onPrimary),
                    )
                  : Text(buttonText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            tokens.background.withValues(alpha: 0),
            tokens.background.withValues(alpha: 0.94),
          ],
          stops: const [0, 0.3],
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: child,
        ),
      ),
    );
  }

  Widget _buildLotteryRules() {
    final tokens = AppThemeTokens.of(context);
    Widget row(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 16, color: tokens.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: tokens.textSecondary)),
              ),
            ],
          ),
        );
    return LotteryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LotterySectionTitle('参与规则', size: 15),
          row(Icons.school_outlined, '已完成教务连接并同步课表配置的账号即可参与，每个账号仅可参与一次'),
          row(Icons.trending_up_rounded,
              '用户等级就是抽奖权重，Lv.几就是几份权重（开奖前按最新等级实时重算）'),
          row(Icons.verified_user_outlined, '系统到点自动按权重公平摇号，并公示置顶公告与站内中奖通知'),
        ],
      ),
    );
  }

  Widget _buildHistorySection() {
    final tokens = AppThemeTokens.of(context);
    final subStyle = TextStyle(fontSize: 13, color: tokens.textSecondary);

    return LotteryCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: LotterySectionTitle('往期记录')),
              if (_historyLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_historyError != null) ...[
            Semantics(
                liveRegion: true,
                child: Text(_historyError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
            TextButton.icon(
              onPressed: _fetchHistory,
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载往期记录'),
            ),
          ] else if (_historyLoading && _history.isEmpty)
            Text('正在加载往期记录…', style: subStyle)
          else if (_history.isEmpty)
            Text('暂无往期记录', style: subStyle)
          else
            for (var i = 0; i < _history.length; i++) ...[
              if (i > 0) Divider(height: 1, color: tokens.divider),
              _buildHistoryRow(_history[i]),
            ],
        ],
      ),
    );
  }

  Widget _buildHistoryRow(LotteryEvent item) {
    final tokens = AppThemeTokens.of(context);
    final winnerText = item.isDrawn
        ? (item.winner?.nickname ??
            (item.winnerId != null ? '已注销用户' : '暂无中奖者'))
        : item.statusLabel;
    final drawnAt =
        formatLotteryBeijing(item.drawnAt ?? item.drawTime, withYear: false);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 48,
            child: LotteryPrizeArt(
                imagePath: item.prizeImage, radius: 10, iconSize: 32),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.prizeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tokens.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.title} · $drawnAt · ${item.participantCount} 人参与',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: tokens.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  '结果：$winnerText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: tokens.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
