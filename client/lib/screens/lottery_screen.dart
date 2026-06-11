import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';
import 'dart:async';
import '../models/lottery.dart';
import '../providers/auth_provider.dart';
import '../utils/app_feedback.dart';
import '../config/api_constants.dart';
import '../widgets/cached_avatar.dart';
import '../main.dart'; // for GlobalBackgroundWrapper

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

  Future<void> _fetchLottery() async {
    if (mounted) setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
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
        _startCountdown();
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        if (mounted) setState(() {
          _isLoading = false;
          _errorMessage = "暂无抽奖活动";
        });
      } else {
        if (mounted) setState(() {
          _isLoading = false;
          _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _isLoading = false;
        _errorMessage = '发生未知错误';
      });
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  String _formatCountdown(DateTime target) {
    final diff = target.difference(DateTime.now());
    if (diff.isNegative) return "00:00:00";
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
    if (diff.inDays > 0) {
      return "${diff.inDays}天 $h:$m:$s";
    }
    return "$h:$m:$s";
  }

  Future<void> _joinLottery() async {
    if (_event == null || _isSubmitting) return;
    if (mounted) setState(() => _isSubmitting = true);
    try {
      final response = await _dio.post('/lottery/${_event!.id}/join');
      AppFeedback.showSnackBar(context, '参与成功！');
      if (mounted) {
        setState(() {
          _joined = true;
          _myWeight = response.data['weight'] ?? 0;
          _participantCount++;
          _isSubmitting = false;
        });
      }
    } on DioException catch (e) {
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '参与失败'),
        isError: true,
      );
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _adminDraw() async {
    if (_event == null || _isSubmitting) return;
    final confirm = await AppFeedback.confirmDanger(
      context,
      title: '手动开奖',
      message: '确定要立即对该活动开奖吗？此操作不可逆，将立刻按权重抽取一名幸运儿。',
    );
    if (!confirm) return;

    if (mounted) setState(() => _isSubmitting = true);
    try {
      await _dio.post('/admin/lottery/${_event!.id}/draw');
      AppFeedback.showSnackBar(context, '开奖成功！');
      _fetchLottery();
    } on DioException catch (e) {
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '开奖失败'),
        isError: true,
      );
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true;

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('官方抽奖'),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        extendBodyBehindAppBar: true,
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.inbox_rounded,
                              size: 80,
                              color: isDark ? Colors.white30 : Colors.black26),
                          const SizedBox(height: 16),
                          Text(_errorMessage!,
                              style: TextStyle(
                                  fontSize: 16,
                                  color: isDark ? Colors.white70 : Colors.black54)),
                        ],
                      ),
                    )
                  : _buildEventContent(context, primary, isDark, isAdmin),
        ),
      ),
    );
  }

  Widget _buildEventContent(
      BuildContext context, Color primary, bool isDark, bool isAdmin) {
    final ev = _event!;
    final isOngoing = ev.status == 0;
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Icon(Icons.card_giftcard, size: 100, color: Colors.white.withValues(alpha: 0.9)),
          const SizedBox(height: 24),
          Text(
            ev.title,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: [Shadow(color: Colors.black26, blurRadius: 10)],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            ev.description,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: Colors.white70),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark ? Colors.black45 : Colors.white.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                )
              ],
            ),
            child: Column(
              children: [
                const Text('🎁 奖品',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey)),
                const SizedBox(height: 8),
                Text(
                  ev.prizeName,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatItem('当前参与', '$_participantCount人', isDark),
                    _buildStatItem('预计开奖', isOngoing ? _formatCountdown(ev.drawTime) : '已结束', isDark),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (isOngoing) ...[
            if (_joined)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_outline, color: Colors.green),
                    const SizedBox(width: 8),
                    Text(
                      '已参与，当前权重: $_myWeight\n(基础1 + 等级加成)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _joinLottery,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    elevation: 8,
                  ),
                  child: _isSubmitting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('立即参与',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: primary.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Text('🎉 中奖名单',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  if (ev.winner != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CachedAvatar(
                          radius: 24,
                          imageUrl: ev.winner!.avatar.isNotEmpty
                              ? ApiConstants.fullUrl(ev.winner!.avatar)
                              : null,
                          fallbackText: ev.winner!.nickname,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          ev.winner!.nickname,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    )
                  else
                    const Text('暂无中奖者', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ],
          if (isAdmin && isOngoing) ...[
            const SizedBox(height: 40),
            TextButton.icon(
              onPressed: _adminDraw,
              icon: const Icon(Icons.flash_on, color: Colors.orange),
              label: const Text('管理员手动开奖', style: TextStyle(color: Colors.orange)),
              style: TextButton.styleFrom(
                backgroundColor: Colors.orange.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, bool isDark) {
    return Column(
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : Colors.grey[600])),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87)),
      ],
    );
  }
}
