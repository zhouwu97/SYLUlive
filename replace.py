import os

filepath = r"e:\AI\xynewui\client\lib\screens\lottery_screen.dart"
with open(filepath, "r", encoding="utf-8") as f:
    content = f.read()

parts = content.split("  String _formatCountdown(DateTime target) {", 1)
if len(parts) == 2:
    new_content = parts[0] + """  String _formatCountdown(DateTime target) {
    final diff = target.difference(DateTime.now());

    if (diff <= Duration.zero) {
      return '即将开奖';
    }

    final days = diff.inDays;
    final hours = diff.inHours % 24;
    final minutes = diff.inMinutes % 60;
    final seconds = diff.inSeconds % 60;

    if (days > 0) {
      return '${days}天 ${hours}时 ${minutes}分';
    }

    if (hours > 0) {
      return '${hours}时 ${minutes}分';
    }

    return '${minutes}分 ${seconds}秒';
  }

  Future<void> _joinLottery() async {
    if (_event == null || _isSubmitting) return;
    if (mounted) setState(() => _isSubmitting = true);
    try {
      final response = await _dio.post('/lottery/${_event!.id}/join');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '参与成功！');
      setState(() {
        _joined = true;
        _myWeight = response.data['weight'] ?? 0;
        _participantCount++;
        _isSubmitting = false;
      });
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

    if (mounted) setState(() => _isSubmitting = true);
    try {
      await _dio.post('/admin/lottery/${_event!.id}/draw');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '开奖成功！');
      _fetchLottery();
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final user = context.watch<AuthProvider>().user;
    final isSuperAdmin = user?.isSuperAdmin == true;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF06080D)
          : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('官方抽奖'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [
                          Color(0xFF06080D),
                          Color(0xFF10131A),
                          Color(0xFF06080D),
                        ]
                      : const [
                          Color(0xFFF4F6FB),
                          Color(0xFFEFF3F8),
                          Color(0xFFF8FAFC),
                        ],
                ),
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
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  )
                : _buildEventContent(context, primary, isDark, isSuperAdmin),
          ),
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
    final isOngoing = ev.status == 0;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          _buildEventHero(ev, primary, isDark),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '本期奖品',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : const Color(0xFF596170),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildPrizeCard(ev, isOngoing, primary, isDark),
          const SizedBox(height: 18),
          if (isOngoing) ...[
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
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                    shadowColor: primary.withValues(alpha: 0.4),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
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
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '抽奖说明',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white54 : const Color(0xFF8A8F9C),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildLotteryRules(primary, isDark),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark
                    ? primary.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: primary.withValues(alpha: 0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    '🎉 中奖名单',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                    ),
                  ),
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
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    )
                  else
                    const Text('暂无中奖者', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
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
        ],
      ),
    );
  }

  Widget _buildEventHero(LotteryEvent event, Color primary, bool isDark) {
    final titleColor = isDark ? Colors.white : const Color(0xFF20232A);
    final subtitleColor = isDark ? Colors.white70 : const Color(0xFF7D8492);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  primary.withValues(alpha: 0.24),
                  primary.withValues(alpha: 0.10),
                ]
              : const [
                  Color(0xFFF0EFFF),
                  Color(0xFFF8F7FF),
                ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: primary.withValues(alpha: isDark ? 0.20 : 0.10),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.card_giftcard_rounded,
              size: 32,
              color: primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                if (event.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    event.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: subtitleColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrizeCard(LotteryEvent event, bool isOngoing, Color primary, bool isDark) {
    final cardColor = isDark ? const Color(0xFF151A24) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF20232A);
    final secondaryColor = isDark ? Colors.white60 : const Color(0xFF8A8F9C);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.07)
              : const Color(0xFFEEF0F4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.redeem_rounded,
                  color: primary,
                  size: 25,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.prizeName,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '官方活动奖品',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Divider(
            height: 1,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEEF0F4),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildInfoCell(
                  label: '当前参与',
                  value: '$_participantCount 人',
                  isDark: isDark,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFEEF0F4),
              ),
              Expanded(
                child: _buildInfoCell(
                  label: '距离开奖',
                  value: isOngoing ? _formatCountdown(event.drawTime) : '已结束',
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCell({required String label, required String value, required bool isDark}) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white54 : const Color(0xFF8A8F9C),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : const Color(0xFF20232A),
          ),
        ),
      ],
    );
  }

  Widget _buildJoinedCard(bool isDark) {
    const success = Color(0xFF42B36F);
    final bonusWeight = (_myWeight - 1).clamp(0, 1 << 30);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? success.withValues(alpha: 0.13)
            : const Color(0xFFEAF8F0),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: success.withValues(alpha: 0.26),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: success.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              color: success,
            ),
          ),
          const SizedBox(width: 12),
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
                const SizedBox(height: 3),
                Text(
                  '基础 1 · 经验加成 $bonusWeight',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : const Color(0xFF718079),
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
                  color: isDark ? Colors.white54 : const Color(0xFF718079),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLotteryRules(Color primary, bool isDark) {
    final textColor = isDark ? Colors.white70 : const Color(0xFF596170);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151A24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.07)
              : const Color(0xFFEEF0F4),
        ),
      ),
      child: Column(
        children: [
          _buildRuleRow(
            Icons.person_outline_rounded,
            '每个账号仅可参与一次',
            primary,
            textColor,
          ),
          const SizedBox(height: 13),
          _buildRuleRow(
            Icons.trending_up_rounded,
            '基础权重 1，经验每 10 点增加 1 权重',
            primary,
            textColor,
          ),
          const SizedBox(height: 13),
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

  Widget _buildRuleRow(IconData icon, String text, Color primary, Color textColor) {
    return Row(
      children: [
        Icon(icon, size: 16, color: primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
            ),
          ),
        ),
      ],
    );
  }
}
"""
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(new_content)
    print("Replace done.")
else:
    print("Could not find the target string to split on.")
