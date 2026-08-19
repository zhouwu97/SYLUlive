import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/webvpn_service.dart';
import '../features/campus_data/erke/erke_repository.dart';
import '../features/campus_data/erke/erke_models.dart';
import '../features/campus_data/storage/erke_cache_store.dart';
import '../features/personal_data_sync/personal_data_sync_coordinator.dart';
import '../features/personal_data_sync/erke_snapshot_upload.dart';
import '../features/personal_data_sync/personal_data_sync_models.dart';
import '../features/personal_data_sync/personal_data_sync_result.dart';
import '../providers/edu_provider.dart';
import '../theme/app_colors.dart';
import '../utils/app_feedback.dart';
import '../widgets/erke_snapshot_upload_dialog.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class ErkeScoreScreen extends StatefulWidget {
  const ErkeScoreScreen({super.key});

  @override
  State<ErkeScoreScreen> createState() => _ErkeScoreScreenState();
}

class _ErkeScoreScreenState extends State<ErkeScoreScreen> {
  final _casPwdCtrl = TextEditingController();
  final _erkePwdCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();

  final WebVpnService _vpn = WebVpnService();
  late ErkeCacheStore _cache;
  late ErkeRepository _repo;
  String _repositoryNamespace = '';

  bool _isLoading = false;
  String _loadingMessage = '';
  bool _obscureCas = true;
  bool _obscureErke = true;
  String? _filterCategory;

  /// 0 = 毕业要求, 1 = 学年要求
  int _selectedMode = 0;

  /// 强制显示登录表单（即使有缓存数据）
  bool _forceShowLogin = false;

  static const _loadingMessages = [
    '正在穿透学校内网，请稍候…',
    '正在通过统一认证…',
    '正在进入二课平台…',
    '正在抓取成绩数据…',
  ];

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _bindRepository(
      appUserId: user?.id.toString() ?? '',
      sourceAccountId: user?.studentId ?? '',
    );
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
    _clearLegacySavedPasswords();
    _loadCache();
  }

  // ==================================================================
  //  缓存
  // ==================================================================

  void _bindRepository({
    required String appUserId,
    required String sourceAccountId,
  }) {
    final namespace = '$appUserId|$sourceAccountId';
    if (_repositoryNamespace == namespace) return;
    _repositoryNamespace = namespace;
    _cache = ErkeCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
    );
    _repo = ErkeRepository(vpnService: _vpn, cacheStore: _cache);
  }

  Future<void> _loadCache() async {
    try {
      await _repo.loadCache();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _clearLegacySavedPasswords() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      await prefs.remove('erke_cas_pwd');
      await prefs.remove('erke_erke_pwd');
    } catch (_) {}
  }

  @override
  void dispose() {
    _casPwdCtrl.dispose();
    _erkePwdCtrl.dispose();
    _studentIdCtrl.dispose();
    _vpn.dispose();
    super.dispose();
  }

  // ==================================================================
  //  查询
  // ==================================================================

  Future<void> _queryScores() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先在「我的」页面登录后再查询', isError: true);
      return;
    }

    final casPwd = _casPwdCtrl.text;
    final erkePwd = _erkePwdCtrl.text;
    final studentId = _studentIdCtrl.text.trim();

    if (casPwd.isEmpty || erkePwd.isEmpty || studentId.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写完整信息');
      return;
    }

    _bindRepository(
      appUserId: auth.user!.id.toString(),
      sourceAccountId: studentId,
    );

    setState(() {
      _isLoading = true;
      _loadingMessage = _loadingMessages.first;
    });
    _startMessageRotation();

    try {
      _updateMessage('正在通过统一认证…');
      final syncResult = await PersonalDataSyncCoordinator(
        academicGateway: EduProviderPersonalAcademicSyncGateway(
          context.read<EduProvider>(),
        ),
        erkeGateway: ErkeRepositoryPersonalSyncGateway(
          repository: _repo,
          requestCredentials: () async => PersonalErkeCredentials(
            studentId: studentId,
            casPassword: casPwd,
            erkePassword: erkePwd,
          ),
          snapshotUploader: ErkeSnapshotUploadGateway(auth.dio),
          uploadPolicyStore: PreferenceErkeSnapshotUploadPolicyStore(
            appUserId: auth.user!.id.toString(),
          ),
          requestUploadPolicy: _requestErkeSnapshotUploadPolicy,
        ),
      ).sync(
        datasets: const <PersonalSyncDataset>{PersonalSyncDataset.erke},
        trigger: PersonalSyncTrigger.erkePage,
      );
      if (!mounted) return;
      final item = syncResult.items[PersonalSyncDataset.erke];

      if (item?.status != PersonalSyncItemStatus.success) {
        final message = item?.message ?? _repo.fetchError ?? '更新失败';
        AppFeedback.showSnackBar(context, '查询失败：$message', isError: true);
        _forceShowLogin = false; // 保留旧缓存展示
        if (mounted) setState(() {});
        return;
      }

      _forceShowLogin = false;
      if (mounted) setState(() {});
      if (item?.isPartial == true ||
          (item?.message != null && item!.message!.contains('失败'))) {
        AppFeedback.warning(
          '二课数据已更新；${item?.message}',
          context: context,
        );
      } else {
        AppFeedback.success(
          '二课数据已更新${item?.message == null ? '' : '；${item!.message}'}',
          context: context,
        );
      }
    } catch (e) {
      final rawError = (_repo.fetchError?.trim().isNotEmpty == true)
          ? _repo.fetchError!
          : '网络请求异常';
      debugPrint('[Erke] 查询阶段失败: ${e.runtimeType}');
      if (!mounted) return;

      AppFeedback.showSnackBar(
        context,
        '查询失败：$rawError',
        isError: true,
      );
    } finally {
      _stopMessageRotation();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _switchingYear = false;

  Future<void> _switchYear(String targetYear) async {
    if (_switchingYear) return;
    if (!_repo.hasLiveSession) {
      AppFeedback.showSnackBar(context, '会话已过期，请重新登录', isError: true);
      return;
    }
    _switchingYear = true;
    try {
      await _repo.fetchYearlySummary(targetYear);
      if (_repo.yearlyError != null && mounted) {
        AppFeedback.showSnackBar(context, _repo.yearlyError!, isError: true);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          '切换学年失败：${_repo.yearlyError ?? e.toString()}',
          isError: true,
        );
      }
    } finally {
      _switchingYear = false;
      if (mounted) setState(() {});
    }
  }

  void _startMessageRotation() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 4));
      if (!_isLoading || !mounted) return false;
      final curIdx = _loadingMessages.indexOf(_loadingMessage);
      if (curIdx >= 0 && curIdx < _loadingMessages.length - 1) {
        setState(() => _loadingMessage = _loadingMessages[curIdx + 1]);
      }
      return _isLoading;
    });
  }

  void _updateMessage(String msg) {
    if (mounted) setState(() => _loadingMessage = msg);
  }

  void _stopMessageRotation() {}

  Future<ErkeSnapshotUploadPolicy> _requestErkeSnapshotUploadPolicy() async {
    final policy = await showErkeSnapshotUploadDialog(context);
    return policy ?? ErkeSnapshotUploadPolicy.askEveryUpdate;
  }

  Future<void> _deleteUploadedErkeSnapshot() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先登录', isError: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除已上传二课快照？'),
        content: const Text('删除后校园 Agent 将无法继续读取该快照。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ErkeSnapshotUploadGateway(auth.dio).delete();
      if (mounted) AppFeedback.showSnackBar(context, '已删除服务端二课快照');
    } on ErkeSnapshotUploadException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, error.message, isError: true);
      }
    }
  }

  Color _accent(bool isDark) => AppColors.brandPrimary;

  Color _accentSoft(bool isDark) =>
      isDark ? AppColors.brandSurfaceDark : AppColors.brandSurfaceLight;

  Color _success(bool isDark) => AppColors.success;

  Color _successSoft(bool isDark) =>
      isDark ? AppColors.successSurfaceDark : AppColors.successSurfaceLight;

  Color _warning(bool isDark) => AppColors.warning;

  Color _warningSoft(bool isDark) =>
      isDark ? AppColors.warningSurfaceDark : AppColors.warningSurfaceLight;

  Color _danger(bool isDark) => AppColors.danger;

  Color _dangerSoft(bool isDark) =>
      isDark ? AppColors.dangerSurfaceDark : AppColors.dangerSurfaceLight;

  Color _text(bool isDark) =>
      isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;

  Color _subText(bool isDark) =>
      isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

  Color _mutedText(bool isDark) =>
      isDark ? AppColors.iconMutedDark : AppColors.textMutedLight;

  Color _cardBg(bool isDark) =>
      isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight;

  Color _border(bool isDark) =>
      isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;

  Color _progressColor(double percent, bool isDark, {bool isGraduation = true}) {
    if (percent >= 100) return _success(isDark);
    if (!isGraduation && percent < 100) return _warning(isDark);
    return _accent(isDark);
  }

  BoxDecoration _softCardDecoration(bool isDark) {
    return BoxDecoration(
      color: _cardBg(isDark),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _border(isDark)),
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

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4),
      appBar: AppBar(
        title:
            const Text('二课成绩查询', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor:
            isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          if (_repo.hasCachedData)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'relogin') {
                  // 保留缓存，只重置在线会话
                  _repo.resetLiveSession();
                  _forceShowLogin = true;
                  setState(() {});
                } else if (value == 'clear_cache') {
                  await _repo.clearCachedData();
                  _forceShowLogin = true;
                  if (context.mounted) {
                    AppFeedback.showSnackBar(context, '本地缓存已清除');
                    setState(() {});
                  }
                } else if (value == 'delete_uploaded_snapshot') {
                  await _deleteUploadedErkeSnapshot();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'relogin',
                  child: Text('更新二课数据'),
                ),
                const PopupMenuItem(
                    value: 'clear_cache', child: Text('清除本地缓存')),
                const PopupMenuItem(
                  value: 'delete_uploaded_snapshot',
                  child: Text('删除已上传二课快照'),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: (_repo.hasCachedData && !_forceShowLogin)
            ? _buildDataView(isDark)
            : _buildLoginForm(),
      ),
    );
  }

  // ==================================================================
  //  Login Form
  // ==================================================================

  Widget _buildLoginForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final studentId =
        _studentIdCtrl.text.isNotEmpty ? _studentIdCtrl.text : '未登录';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2226) : const Color(0xFFEAF6F3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFE2EFEA),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    color: Color(0xFF147C72), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '学号 $studentId 已自动识别，请完成双重密码验证',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : const Color(0xFF147C72),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: _softCardDecoration(isDark),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('验证信息',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87)),
                const SizedBox(height: 20),
                Row(children: [
                  const Text('1 统一认证密码',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('VPN 穿透专用',
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.grey[500])),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: _casPwdCtrl,
                  obscureText: _obscureCas,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '输入统一身份认证密码',
                    prefixIcon: const Icon(Icons.lock_outline, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscureCas ? Icons.visibility_off : Icons.visibility,
                          size: 18),
                      onPressed: () =>
                          setState(() => _obscureCas = !_obscureCas),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : const Color(0xFFF5F7F8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 24),
                Row(children: [
                  const Text('2 二课查询密码',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('系统登录专用',
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.grey[500])),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: _erkePwdCtrl,
                  obscureText: _obscureErke,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '输入二课平台登录密码',
                    prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscureErke
                              ? Icons.visibility_off
                              : Icons.visibility,
                          size: 18),
                      onPressed: () =>
                          setState(() => _obscureErke = !_obscureErke),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : const Color(0xFFF5F7F8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _queryScores,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF147C72),
                disabledBackgroundColor:
                    const Color(0xFF147C72).withValues(alpha: 0.4),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                elevation: 0,
              ),
              child: Text(
                _isLoading ? '更新中...' : '更新二课数据',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          if (_isLoading) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: _softCardDecoration(isDark),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('查询进度',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF147C72)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _loadingMessage.isNotEmpty
                              ? _loadingMessage
                              : '系统正在自动完成 WebVPN 穿透',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 30),
            Text('提示：系统会自动完成 WebVPN 穿透',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.grey[500])),
          ],
        ],
      ),
    );
  }

  // ==================================================================
  //  Data View (登录后)
  // ==================================================================

  Widget _buildDataView(bool isDark) {
    return Column(
      children: [
        // 模式切换
        _buildModeSwitcher(isDark),
        // 内容区
        Expanded(
          child: _selectedMode == 0
              ? _buildGraduationView(isDark)
              : _buildYearlyView(isDark),
        ),
      ],
    );
  }

  // ---- 分段选择器 ----

  Widget _buildModeSwitcher(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            _modeTab('毕业要求', 0, isDark),
            _modeTab('学年要求', 1, isDark),
          ],
        ),
      ),
    );
  }

  Widget _modeTab(String label, int index, bool isDark) {
    final selected = _selectedMode == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedMode = index),
        child: Container(
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: selected ? _accentSoft(isDark) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? _accent(isDark) : _subText(isDark),
            ),
          ),
        ),
      ),
    );
  }

  // ==================================================================
  //  毕业要求页
  // ==================================================================

  Widget _buildGraduationView(bool isDark) {
    final grad = _repo.graduation;
    if (grad == null) return _buildNeedsRelogin(isDark, '毕业要求');

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGraduationProgressCard(grad, isDark),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '分类完成情况',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: _text(isDark),
              ),
            ),
          ),
          _buildGraduationCategoryList(grad, isDark),
          if (grad.officialConclusion.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildConclusionCard(grad.officialConclusion, isDark),
          ],
          const SizedBox(height: 20),
          _buildActivitySection(isDark, year: null),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildGraduationProgressCard(ErkeGraduationSummary grad, bool isDark) {
    final percentage = grad.percentage;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardBg(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '毕业要求完成度',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _text(isDark),
                ),
              ),
              const Spacer(),
              Text(
                '${percentage.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _progressColor(percentage, isDark, isGraduation: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 进度条——主视觉
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percentage / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : AppColors.brandSurfaceLight,
              valueColor: AlwaysStoppedAnimation<Color>(
                _progressColor(percentage, isDark, isGraduation: true),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 差距信息
          Row(
            children: [
              if (grad.graduationGap > 0) ...[
                _infoTag(
                  '按分类最低还需 ${_formatScore(grad.graduationGap)} 分',
                  _warning(isDark),
                  bg: _warningSoft(isDark),
                ),
                const SizedBox(width: 12),
              ] else ...[
                _infoTag(
                  '已达标 ✓',
                  _success(isDark),
                  bg: _successSoft(isDark),
                ),
                const SizedBox(width: 12),
              ],
              if (grad.unmetCount > 0)
                _infoTag(
                  '分类未达标 ${grad.unmetCount} 项',
                  _warning(isDark),
                  bg: _warningSoft(isDark),
                )
              else
                _infoTag(
                  '全部分类已达标',
                  _success(isDark),
                  bg: _successSoft(isDark),
                ),
            ],
          ),
          if (grad.unmetCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              grad.categories
                  .where((c) => !c.meetsNumerically)
                  .map((c) => '${c.name}差${_formatScore(c.gap)}')
                  .join(' · '),
              style: TextStyle(fontSize: 12, color: _subText(isDark)),
            ),
          ],
          const SizedBox(height: 12),
          // 学校累计总分——与百分比分开，不产生矛盾
          Row(
            children: [
              Text(
                '累计活动总分',
                style: TextStyle(fontSize: 13, color: _subText(isDark)),
              ),
              const Spacer(),
              Text(
                '${_formatScore(grad.earnedTotal)} / ${_formatScore(grad.requiredTotal)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _text(isDark),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGraduationCategoryList(ErkeGraduationSummary grad, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border(isDark)),
      ),
      child: Column(
        children: grad.categories.asMap().entries.map((entry) {
          final i = entry.key;
          final cat = entry.value;
          final isLast = i == grad.categories.length - 1;
          return Column(
            children: [
              _buildGraduationCategoryRow(cat, isDark),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: _border(isDark),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGraduationCategoryRow(ErkeRequirementCategory cat, bool isDark) {
    final isOk = cat.meetsNumerically;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              cat.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _text(isDark),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isOk ? _successSoft(isDark) : _warningSoft(isDark),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              isOk ? '已完成' : '差 ${cat.gap.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isOk ? _success(isDark) : _warning(isDark),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_formatScore(cat.earned)} / ${_formatScore(cat.required)}',
            style: TextStyle(fontSize: 13, color: _subText(isDark)),
          ),
        ],
      ),
    );
  }

  // ---- 官方结论 ----

  Widget _buildConclusionCard(String conclusion, bool isDark) {
    Color color = _success(isDark);
    Color bg = _successSoft(isDark);
    if (conclusion.contains('严重') ||
        conclusion.contains('不可') ||
        conclusion.contains('未满足')) {
      color = _danger(isDark);
      bg = _dangerSoft(isDark);
    } else if (conclusion.contains('不足') ||
        conclusion.contains('未达标') ||
        conclusion.contains('未完成') ||
        conclusion.contains('还需') ||
        conclusion.contains('缺少')) {
      color = _warning(isDark);
      bg = _warningSoft(isDark);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '官方结论：$conclusion',
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================================================================
  //  学年要求页
  // ==================================================================

  Widget _buildYearlyView(bool isDark) {
    final yr = _repo.yearly;
    if (yr == null) return _buildNeedsRelogin(isDark, '学年要求');

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildYearSelector(yr, isDark),
          const SizedBox(height: 12),
          _buildYearlyProgressCard(yr, isDark),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '本学年分类情况',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: _text(isDark),
              ),
            ),
          ),
          _buildYearlyCategoryList(yr, isDark),
          if (yr.officialConclusion.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildConclusionCard(yr.officialConclusion, isDark),
          ],
          const SizedBox(height: 20),
          _buildActivitySection(isDark, year: yr.year),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildYearSelector(ErkeYearlySummary yr, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _cardBg(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border(isDark)),
      ),
      child: Row(
        children: [
          Text(
            '学年',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _text(isDark),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: yr.availableYears.contains(yr.year) ? yr.year : null,
                isExpanded: true,
                icon: const Icon(Icons.chevron_right_rounded, size: 18),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _text(isDark),
                ),
                items: yr.availableYears.map((y) {
                  return DropdownMenuItem(value: y, child: Text('$y 学年'));
                }).toList(),
                onChanged: (v) {
                  if (v != null && v != yr.year) _switchYear(v);
                },
              ),
            ),
          ),
          if (_repo.isYearlyLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.brandPrimary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildYearlyProgressCard(ErkeYearlySummary yr, bool isDark) {
    final percentage = yr.percentage;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardBg(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '本学年要求完成度',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _text(isDark),
                ),
              ),
              const Spacer(),
              Text(
                '${percentage.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _progressColor(percentage, isDark, isGraduation: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatScore(yr.yearEarnedTotal),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: _text(isDark),
                ),
              ),
              Text(
                ' / ${_formatScore(yr.requiredTotal)}',
                style: TextStyle(fontSize: 18, color: _subText(isDark)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percentage / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : AppColors.brandSurfaceLight,
              valueColor: AlwaysStoppedAnimation<Color>(
                _progressColor(percentage, isDark, isGraduation: false),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (yr.minimumGap > 0)
            _infoTag(
              '按分类最低还需 ${_formatScore(yr.minimumGap)} 分',
              _warning(isDark),
              bg: _warningSoft(isDark),
            )
          else
            _infoTag(
              '已达标 ✓',
              _success(isDark),
              bg: _successSoft(isDark),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '本学年实际获得 ${_formatScore(yr.yearEarnedTotal)}',
                style: TextStyle(fontSize: 13, color: _subText(isDark)),
              ),
              const Spacer(),
              Text(
                '累计总分 ${_formatScore(yr.cumulativeTotal)}',
                style: TextStyle(fontSize: 13, color: _subText(isDark)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildYearlyCategoryList(ErkeYearlySummary yr, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border(isDark)),
      ),
      child: Column(
        children: yr.categories.asMap().entries.map((entry) {
          final i = entry.key;
          final cat = entry.value;
          final isLast = i == yr.categories.length - 1;
          return Column(
            children: [
              _buildYearlyCategoryRow(cat, isDark),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: _border(isDark),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildYearlyCategoryRow(ErkeYearlyCategory cat, bool isDark) {
    final isOk = cat.meetsNumerically;
    final scoreStr = _formatScore(cat.yearEarned);
    final reqStr = _formatScore(cat.required);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行：名称 + 状态 + 分值
          Row(
            children: [
              Expanded(
                child: Text(
                  cat.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _text(isDark),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isOk ? _successSoft(isDark) : _warningSoft(isDark),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  isOk ? '已完成' : '本学年未达标',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isOk ? _success(isDark) : _warning(isDark),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 58,
                child: Text(
                  '$scoreStr / $reqStr',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13, color: _subText(isDark)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          // 第二行：累计（右对齐，淡色）
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '累计 ${_formatScore(cat.cumulative)}',
              style: TextStyle(fontSize: 11, color: _mutedText(isDark)),
            ),
          ),
        ],
      ),
    );
  }

  // ==================================================================
  //  活动列表 (共用)
  // ==================================================================

  Widget _buildActivitySection(bool isDark, {String? year}) {
    final acts = _repo.activities;
    final title = year != null ? '$year 学年活动' : '全部活动';

    // 收集分类用于筛选
    final categorySet = <String>{};
    for (final a in acts) {
      if (a.category.isNotEmpty) categorySet.add(a.category);
    }
    final categories = categorySet.toList()..sort();

    // 筛选
    final filtered = _filterCategory == null
        ? acts
        : acts.where((a) => a.category == _filterCategory).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行
        Row(
          children: [
            Text(
              '$title ${filtered.length}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _text(isDark),
              ),
            ),
            const Spacer(),
            if (categories.isNotEmpty)
              InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _showFilterSheet(context, categories),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: _accentSoft(isDark),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '筛选',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _accent(isDark),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.filter_list, size: 16, color: _accent(isDark)),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                '该分类暂无数据',
                style: TextStyle(color: _subText(isDark)),
              ),
            ),
          )
        else
          ...filtered.map((a) => _buildActivityItem(a, isDark)),
      ],
    );
  }

  void _showFilterSheet(BuildContext context, List<String> categories) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppColors.surfaceSecondaryDark
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择分类',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                title: const Text('全部'),
                trailing: _filterCategory == null
                    ? const Icon(Icons.check, color: AppColors.brandPrimary)
                    : null,
                onTap: () {
                  setState(() => _filterCategory = null);
                  Navigator.pop(context);
                },
              ),
              ...categories.map((c) => ListTile(
                    title: Text(c),
                    trailing: _filterCategory == c
                        ? const Icon(Icons.check, color: AppColors.brandPrimary)
                        : null,
                    onTap: () {
                      setState(() => _filterCategory = c);
                      Navigator.pop(context);
                    },
                  )),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivityItem(ErkeActivity item, bool isDark) {
    final formattedDate = _formatDate(item.date);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: _cardBg(isDark),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border(isDark)),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 54),
                    child: Text(
                      item.item,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        height: 1.35,
                        color: _text(isDark),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (item.category.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            item.category,
                            style: TextStyle(
                              fontSize: 12,
                              color: _accent(isDark),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          formattedDate,
                          style: TextStyle(
                            fontSize: 12,
                            color: _subText(isDark),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Text(
                '+${item.score}',
                style: TextStyle(
                  color: _success(isDark),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    String s = dateStr.replaceAll('-', '.').replaceAll('至', '–');
    s = s.replaceAll(' 00:00:00', '');
    s = s.replaceAllMapped(
        RegExp(r'(\d{2}:\d{2}):00'), (match) => match.group(1)!);

    final sameDayRegex = RegExp(r'^(\d{4}\.\d{2}\.\d{2})(.*?)–\1(.*?)$');
    final sameYearRegex = RegExp(r'^(\d{4})\.(.*?)–\1\.(.*?)$');

    if (sameDayRegex.hasMatch(s)) {
      s = s.replaceFirstMapped(
          sameDayRegex,
          (match) =>
              '${match.group(1)}${match.group(2)}–${match.group(3)?.trim()}');
    } else if (sameYearRegex.hasMatch(s)) {
      s = s.replaceFirstMapped(sameYearRegex,
          (match) => '${match.group(1)}.${match.group(2)}–${match.group(3)}');
    }
    return s;
  }

  // ---- 旧缓存迁移提示 ----

  Widget _buildNeedsRelogin(bool isDark, String mode) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_download_outlined,
              size: 48,
              color: _mutedText(isDark),
            ),
            const SizedBox(height: 16),
            Text(
              '检测到旧版二课缓存',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _text(isDark),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '需要重新验证账号以获取$mode和学年要求。\n已有活动记录已保留，不会丢失。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _subText(isDark),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _queryScores,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent(isDark),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text('验证中...', style: TextStyle(fontSize: 15)),
                        ],
                      )
                    : const Text(
                        '重新登录并补全数据',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 格式化 ----

  /// 保留必要小数：整数不显示小数，一位数据保留一位，两位保留两位
  static String _formatScore(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e9) {
      return v.toInt().toString();
    }
    // 用两位精度，然后去掉末尾多余的零
    final s = v.toStringAsFixed(2);
    if (s.endsWith('00')) return v.toStringAsFixed(0);
    if (s.endsWith('0')) return v.toStringAsFixed(1);
    return s;
  }

  // ---- 标签 ----

  Widget _infoTag(String text, Color color, {Color? bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
