import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/lottery.dart';
import '../providers/auth_provider.dart';
import '../services/async_action_guard.dart';
import '../services/idempotency_key.dart';
import '../services/publish_session_scope.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/cached_avatar.dart';

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

  String _formatCountdown(DateTime target) {
    final diff = target.difference(_now());
    if (diff <= Duration.zero) {
      return '即将开奖';
    }

    final days = diff.inDays;
    final hours = diff.inHours % 24;
    final minutes = diff.inMinutes % 60;
    final seconds = diff.inSeconds % 60;

    if (days > 0) {
      return '$days天 $hours时 $minutes分';
    }
    if (hours > 0) {
      return '$hours时 $minutes分 $seconds秒';
    }
    return '$minutes分 $seconds秒';
  }

  String _formatBeijingDateTime(DateTime value) {
    final bj = value.toUtc().add(const Duration(hours: 8));
    final y = bj.year.toString().padLeft(4, '0');
    final m = bj.month.toString().padLeft(2, '0');
    final d = bj.day.toString().padLeft(2, '0');
    final h = bj.hour.toString().padLeft(2, '0');
    final min = bj.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
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

  BoxDecoration _softCardDecoration(bool isDark, {Color? border}) {
    return BoxDecoration(
      color: isDark ? const Color(0xFF1E2226) : Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : (border ?? const Color(0xFFF4E2C5)),
      ),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      AppPageBackground(builder: _buildPageWithBackground);

  Widget _buildPageWithBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primary = Color(0xFFF59E0B);
    final user = context.watch<AuthProvider>().user;
    final isSuperAdmin = user?.isSuperAdmin == true;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppPageBackground.color(context,
            isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4)),
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
        body: SafeArea(
          top: false,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
                  ? _buildErrorState(isDark)
                  : _isEmpty || _event == null
                      ? _buildEmptyState(primary, isDark)
                      : RefreshIndicator(
                          onRefresh: () => _loadPage(silent: true),
                          child: _buildEventContent(
                            context,
                            primary,
                            isDark,
                            isSuperAdmin,
                          ),
                        ),
        ),
      ),
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 64,
              color: isDark ? Colors.white38 : Colors.black26,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
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

  Widget _buildEmptyState(Color primary, bool isDark) {
    return RefreshIndicator(
      onRefresh: () => _loadPage(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        children: [
          const SizedBox(height: 40),
          Icon(
            Icons.inbox_rounded,
            size: 72,
            color: isDark ? Colors.white30 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '暂无抽奖活动',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ),
          const SizedBox(height: 28),
          _buildHistorySection(primary, isDark),
        ],
      ),
    );
  }

  Widget _buildEventContent(
    BuildContext context,
    Color primary,
    bool isDark,
    bool isSuperAdmin,
  ) {
    final ev = _event!;
    final isOngoing = ev.isOngoing;
    final drawTimeReached = _isDrawTimeReached(ev);
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        children: [
          _buildEventHero(ev, isOngoing, primary, isDark),
          const SizedBox(height: 16),
          _buildPrizeCard(ev, isOngoing, primary, isDark),
          if (ev.description.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildDescriptionCard(ev.description.trim(), isDark, titleColor),
          ],
          const SizedBox(height: 16),
          _buildWinnerCard(ev, primary, isDark, titleColor),
          if (isOngoing) ...[
            const SizedBox(height: 16),
            if (_joined)
              _buildJoinedCard(isDark)
            else
              _buildJoinAction(primary, isDark, drawTimeReached),
            const SizedBox(height: 16),
            _buildLotteryRules(primary, isDark),
          ],
          // 仅到点后仍未开奖时，给超级管理员提供兜底手动补开入口。
          if (isSuperAdmin && isOngoing && drawTimeReached) ...[
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _isSubmitting ? null : _adminDraw,
              icon: const Icon(Icons.flash_on, color: Colors.orange),
              label: const Text(
                '兜底手动补开',
                style: TextStyle(color: Colors.orange),
              ),
              style: TextButton.styleFrom(
                backgroundColor: Colors.orange.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
          if (!isOngoing) ...[
            const SizedBox(height: 20),
            Text(
              '${ev.statusLabel} · 感谢参与',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : const Color(0xFF7D8A97),
              ),
            ),
          ],
          const SizedBox(height: 24),
          _buildHistorySection(primary, isDark),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard(
      String description, bool isDark, Color titleColor) {
    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _softCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '活动说明',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: isDark ? Colors.white70 : const Color(0xFF4B5563),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinAction(Color primary, bool isDark, bool drawTimeReached) {
    final canJoin = !drawTimeReached && _academicConfigured && !_isSubmitting;
    String buttonText = '立即参与';
    if (drawTimeReached) {
      buttonText = '已截止，等待系统开奖';
    } else if (!_academicConfigured) {
      buttonText = '需先连接教务后参与';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_academicConfigured && !drawTimeReached) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: isDark ? 0.14 : 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.school_outlined,
                    size: 18, color: Color(0xFFD97706)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '参与官方抽奖需先完成教务连接并同步课表配置。',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? Colors.amber.shade200
                          : const Color(0xFF92400E),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: canJoin ? _joinLottery : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  isDark ? Colors.white12 : const Color(0xFFE5E7EB),
              disabledForegroundColor:
                  isDark ? Colors.white38 : const Color(0xFF9CA3AF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              elevation: 0,
            ),
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : Text(
                    buttonText,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildWinnerCard(
      LotteryEvent ev, Color primary, bool isDark, Color titleColor) {
    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _softCardDecoration(isDark, border: const Color(0xFFF4E2C5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '开奖结果',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 16),
          if (ev.isOngoing)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    const Icon(Icons.hourglass_empty,
                        color: Color(0xFFF59E0B), size: 32),
                    const SizedBox(height: 12),
                    Text(
                      '暂未开奖',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white : const Color(0xFF1F2328)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '开奖后会在这里公布中奖名单',
                      style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF747B82)),
                    ),
                  ],
                ),
              ),
            )
          else if (ev.isDrawn && ev.winner != null)
            Column(
              children: [
                const Row(
                  children: [
                    Text('🎉 ', style: TextStyle(fontSize: 18)),
                    Text(
                      '恭喜中奖',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFF97316)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    CachedAvatar(
                      radius: 20,
                      imageUrl: ev.winner!.avatar.isNotEmpty
                          ? ApiConstants.fullUrl(ev.winner!.avatar)
                          : null,
                      fallbackText: ev.winner!.nickname,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        ev.winner!.nickname,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white : const Color(0xFF1F2328),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('中奖奖品：',
                        style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF747B82))),
                    Expanded(
                      child: Text(ev.prizeName,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF1F2328))),
                    ),
                  ],
                ),
              ],
            )
          else if (ev.isDrawn && ev.winnerId != null)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('中奖用户已注销', style: TextStyle(color: Colors.grey)),
              ),
            )
          else if (ev.isNoWinner)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child:
                    Text('本期无有效参与者，已流拍', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  ev.isCancelled ? '本期活动已取消' : '暂无中奖者',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEventHero(
      LotteryEvent event, bool isOngoing, Color primary, bool isDark) {
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2226) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFF4E2C5),
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
        gradient: isDark
            ? null
            : const LinearGradient(
                colors: [Color(0xFFFFFDF8), Color(0xFFFFF4E5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本期抽奖',
              style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white70 : const Color(0xFF747B82))),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child:
                    Icon(Icons.card_giftcard_rounded, color: primary, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.prizeName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? Colors.white70
                                    : const Color(0xFF747B82)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('·', style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 8),
                        Text(
                          event.statusLabel,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color:
                                isOngoing ? primary : const Color(0xFF7D8A97),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPrizeCard(
      LotteryEvent event, bool isOngoing, Color primary, bool isDark) {
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _softCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '奖品信息',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            event.prizeName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : const Color(0xFFF97316),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '开奖时间：${_formatBeijingDateTime(event.drawTime)}（北京时间）',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white60 : const Color(0xFF747B82),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前参与',
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF747B82),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_participantCount 人',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: titleColor,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOngoing ? '距离开奖' : '开奖状态',
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF747B82),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isOngoing
                          ? _formatCountdown(event.drawTime)
                          : event.statusLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isOngoing ? titleColor : const Color(0xFF7D8A97),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildJoinedCard(bool isDark) {
    const success = Color(0xFF147C72);

    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration:
          _softCardDecoration(isDark, border: success.withValues(alpha: 0.2)),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: success.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded, color: success),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '已成功参与',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: success,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '当前实时等级权重：$_myWeight 份，开奖时按最新等级计算',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : const Color(0xFF747B82),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$_myWeight',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: success,
                ),
              ),
              Text(
                '当前权重',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white54 : const Color(0xFF747B82),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLotteryRules(Color primary, bool isDark) {
    final textColor = isDark ? Colors.white70 : const Color(0xFF747B82);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _softCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '抽奖说明',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF1F2328),
            ),
          ),
          const SizedBox(height: 16),
          _buildRuleRow(
            Icons.school_outlined,
            '已完成教务连接并同步课表配置的账号即可参与，每个账号仅可参与一次',
            primary,
            textColor,
          ),
          const SizedBox(height: 12),
          _buildRuleRow(
            Icons.trending_up_rounded,
            '用户等级就是抽奖权重，Lv.几就是几份权重（开奖前按最新等级实时重算）',
            primary,
            textColor,
          ),
          const SizedBox(height: 12),
          _buildRuleRow(
            Icons.verified_user_outlined,
            '系统到点自动按权重公平摇号，并公示置顶公告与站内中奖通知',
            primary,
            textColor,
          ),
        ],
      ),
    );
  }

  Widget _buildRuleRow(
      IconData icon, String text, Color primary, Color textColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHistorySection(Color primary, bool isDark) {
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.white60 : const Color(0xFF747B82);

    return AppCardSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _softCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '往期抽奖记录',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
              const Spacer(),
              if (_historyLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
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
            Text('正在加载往期记录…', style: TextStyle(fontSize: 13, color: subColor))
          else if (_history.isEmpty)
            Text('暂无往期记录', style: TextStyle(fontSize: 13, color: subColor))
          else
            ..._history.map((item) {
              final winnerText = item.isDrawn
                  ? (item.winner?.nickname ??
                      (item.winnerId != null ? '已注销用户' : '暂无中奖者'))
                  : item.statusLabel;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : const Color(0xFFFFFAF4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.title} · ${item.prizeName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: titleColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            item.statusLabel,
                            style: TextStyle(fontSize: 12, color: subColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '开奖：${_formatBeijingDateTime(item.drawnAt ?? item.drawTime)} · 参与 ${item.participantCount} 人 · 结果：$winnerText',
                        style: TextStyle(fontSize: 12, color: subColor),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
