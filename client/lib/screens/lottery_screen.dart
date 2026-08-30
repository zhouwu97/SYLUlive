import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'dart:async';
import '../models/lottery.dart';
import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';
import '../config/api_constants.dart';
import '../widgets/cached_avatar.dart';
import '../services/async_action_guard.dart';
import '../services/idempotency_key.dart';

class LotteryScreen extends StatefulWidget {
  const LotteryScreen({super.key});

  @override
  State<LotteryScreen> createState() => _LotteryScreenState();
}

class _LotteryScreenState extends State<LotteryScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  LotteryEvent? _event;
  int _participantCount = 0;
  bool _joined = false;
  int _myWeight = 0;
  bool _isSubmitting = false;
  bool _postDrawRefreshInFlight = false;
  DateTime? _lastPostDrawRefreshAt;
  String? _joinIdempotencyKey;
  String? _drawIdempotencyKey;
  final AsyncActionGuard _actionGuard = AsyncActionGuard();

  late Dio _dio;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _dio = context.read<AuthProvider>().dio;
    _fetchLottery();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchLottery({bool silent = false}) async {
    if (mounted && !silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }
    try {
      final response = await _dio.get('/lottery/current');
      if (mounted) {
        setState(() {
          _event = LotteryEvent.fromJson(response.data['event']);
          _participantCount = response.data['participant_count'] ?? 0;
          _joined = response.data['joined'] ?? false;
          _myWeight = response.data['my_weight'] ?? 0;
          _isLoading = false;
        });
        if (_event?.status == 0) {
          if (_event!.drawTime.isAfter(DateTime.now())) {
            _lastPostDrawRefreshAt = null;
          }
          _startCountdown();
        } else {
          _countdownTimer?.cancel();
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = "暂无抽奖活动";
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '发生未知错误';
        });
      }
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
    if (event == null ||
        event.status != 0 ||
        event.drawTime.isAfter(DateTime.now())) {
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
    _fetchLottery(silent: true).whenComplete(() {
      _postDrawRefreshInFlight = false;
    });
  }

  String _formatCountdown(DateTime target) {
    final diff = target.difference(DateTime.now());

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
      return '$hours时 $minutes分';
    }

    return '$minutes分 $seconds秒';
  }

  Future<void> _joinLottery() async {
    if (_event == null || _isSubmitting) return;
    final eventId = _event!.id;
    await _actionGuard.run<void>(
      'lottery-join:$eventId',
      () => _joinLotteryOnce(eventId),
    );
  }

  Future<void> _joinLotteryOnce(int eventId) async {
    if (mounted) setState(() => _isSubmitting = true);
    try {
      final response = await _dio.post(
        '/lottery/$eventId/join',
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _joinIdempotencyKey ??=
              newIdempotencyKey('lottery-join'),
        }),
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '参与成功！');
      setState(() {
        _joined = true;
        _myWeight = response.data['weight'] ?? 0;
        _participantCount++;
        _isSubmitting = false;
      });
      _joinIdempotencyKey = null;
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '参与失败'),
        isError: true,
      );
      setState(() => _isSubmitting = false);
    }
  }

  Future<void> _adminDraw() async {
    if (_event == null || _isSubmitting) return;
    final confirm = await AppFeedback.confirmDanger(
      context,
      title: '手动开奖',
      message: '确定要立即对该活动开奖吗？此操作不可逆，将立刻按权重抽取一名幸运儿。',
    );
    if (!mounted) return;
    if (!confirm) return;
    final eventId = _event!.id;
    await _actionGuard.run<void>(
      'lottery-draw:$eventId',
      () => _adminDrawOnce(eventId),
    );
  }

  Future<void> _adminDrawOnce(int eventId) async {
    if (mounted) setState(() => _isSubmitting = true);
    try {
      await _dio.post(
        '/admin/lottery/$eventId/draw',
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _drawIdempotencyKey ??=
              newIdempotencyKey('lottery-draw'),
        }),
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '开奖成功！');
      _fetchLottery();
      _drawIdempotencyKey = null;
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '开奖失败'),
        isError: true,
      );
      setState(() => _isSubmitting = false);
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
  Widget build(BuildContext context) {
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
        backgroundColor:
            isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4),
        appBar: AppBar(
          title:
              const Text('官方抽奖', style: TextStyle(fontWeight: FontWeight.bold)),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF111315)
                      : const Color(0xFFFFFAF4),
                ),
              ),
            ),
            SafeArea(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _errorMessage != null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.inbox_rounded,
                                size: 80,
                                color: isDark ? Colors.white30 : Colors.black26,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _errorMessage!,
                                style: TextStyle(
                                  fontSize: 16,
                                  color:
                                      isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        )
                      : _buildEventContent(
                          context, primary, isDark, isSuperAdmin),
            ),
          ],
        ),
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
    final isOngoing = ev.status == 0;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: SafeArea(
        top: true,
        child: Column(
          children: [
            _buildEventHero(ev, isOngoing, primary, isDark),
            const SizedBox(height: 16),
            _buildPrizeCard(ev, isOngoing, primary, isDark),
            const SizedBox(height: 16),
            if (!isOngoing)
              _buildWinnerCard(ev, primary, isDark, titleColor)
            else ...[
              _buildWinnerCard(ev, primary, isDark, titleColor),
              const SizedBox(height: 16),
              if (_joined)
                _buildJoinedCard(isDark)
              else
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _joinLottery,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
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
                        : const Text(
                            '立即参与',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              const SizedBox(height: 16),
              _buildLotteryRules(primary, isDark),
            ],
            if (isSuperAdmin && isOngoing) ...[
              const SizedBox(height: 32),
              TextButton.icon(
                onPressed: _adminDraw,
                icon: const Icon(Icons.flash_on, color: Colors.orange),
                label: const Text(
                  '管理员手动开奖',
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
              const SizedBox(height: 32),
              Text(
                '已结束 · 感谢参与',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF7D8A97),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWinnerCard(
      LotteryEvent ev, Color primary, bool isDark, Color titleColor) {
    return Container(
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
          if (ev.status == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
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
          else if (ev.winner != null)
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
                    Text(ev.prizeName,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF1F2328))),
                  ],
                )
              ],
            )
          else
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('暂无中奖者', style: TextStyle(color: Colors.grey)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEventHero(
      LotteryEvent event, bool isOngoing, Color primary, bool isDark) {
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return Container(
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
                        Text(
                          event.title,
                          style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? Colors.white70
                                  : const Color(0xFF747B82)),
                        ),
                        const SizedBox(width: 8),
                        const Text('·', style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 8),
                        Text(
                          isOngoing ? '进行中' : '已开奖',
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

    return Container(
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
          const SizedBox(height: 16),
          Text(
            event.prizeName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : const Color(0xFFF97316),
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
                      isOngoing ? _formatCountdown(event.drawTime) : '已结束',
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

    return Container(
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
                  '当前等级权重：$_myWeight 份，开奖前按最新等级重算',
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
            Icons.person_outline_rounded,
            '每个账号仅可参与一次',
            primary,
            textColor,
          ),
          const SizedBox(height: 12),
          _buildRuleRow(
            Icons.trending_up_rounded,
            '用户等级就是抽奖权重，Lv.几就是几份权重',
            primary,
            textColor,
          ),
          const SizedBox(height: 12),
          _buildRuleRow(
            Icons.verified_user_outlined,
            '系统按参与者权重随机抽取中奖者',
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
      children: [
        Icon(icon, size: 16, color: primary),
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
}
