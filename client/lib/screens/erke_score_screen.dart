import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../services/webvpn_service.dart';
import '../features/campus_data/erke/erke_repository.dart';
import '../features/campus_data/erke/erke_models.dart';
import '../features/campus_data/storage/erke_cache_store.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';

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
  final ErkeCacheStore _cache = ErkeCacheStore();
  late final ErkeRepository _repo;

  bool _isLoading = false;
  String _loadingMessage = '';
  bool _obscureCas = true;
  bool _obscureErke = true;
  String? _filterCategory;

  String _realCasPwd = '';
  String _realErkePwd = '';

  /// 0 = 毕业要求, 1 = 学年要求
  int _selectedMode = 0;

  static const _loadingMessages = [
    '正在穿透学校内网，请稍候…',
    '正在通过统一认证…',
    '正在进入二课平台…',
    '正在抓取成绩数据…',
  ];

  @override
  void initState() {
    super.initState();
    _repo = ErkeRepository(vpnService: _vpn, cacheStore: _cache);
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
    _loadSavedPasswords();
    _loadCache();
  }

  // ==================================================================
  //  缓存
  // ==================================================================

  Future<void> _loadCache() async {
    try {
      await _repo.loadCache();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadSavedPasswords() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final casPwd = prefs.getString('erke_cas_pwd') ?? '';
      final erkePwd = prefs.getString('erke_erke_pwd') ?? '';
      _realCasPwd = casPwd;
      _realErkePwd = erkePwd;
      _casPwdCtrl.text = casPwd.isNotEmpty ? '•' * casPwd.length : '';
      _erkePwdCtrl.text = erkePwd.isNotEmpty ? '•' * erkePwd.length : '';
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _onCasPwdChanged(String val) {
    final placeholder = '•' * _realCasPwd.length;
    if (_realCasPwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('•', '');
      _realCasPwd = '';
      _casPwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _onErkePwdChanged(String val) {
    final placeholder = '•' * _realErkePwd.length;
    if (_realErkePwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('•', '');
      _realErkePwd = '';
      _erkePwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  Future<void> _savePasswords(String casPwd, String erkePwd) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('erke_cas_pwd', casPwd);
    await prefs.setString('erke_erke_pwd', erkePwd);
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

    final inputCasPwd = _casPwdCtrl.text;
    final inputErkePwd = _erkePwdCtrl.text;
    final casPwd =
        inputCasPwd == ('•' * _realCasPwd.length) ? _realCasPwd : inputCasPwd;
    final erkePwd = inputErkePwd == ('•' * _realErkePwd.length)
        ? _realErkePwd
        : inputErkePwd;
    final studentId = _studentIdCtrl.text.trim();

    if (casPwd.isEmpty || erkePwd.isEmpty || studentId.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写完整信息');
      return;
    }

    _savePasswords(casPwd, erkePwd);

    setState(() {
      _isLoading = true;
      _loadingMessage = _loadingMessages.first;
    });
    _startMessageRotation();

    try {
      _updateMessage('正在通过统一认证…');
      await _repo.loginAndFetch(studentId, casPwd, erkePwd);

      if (_repo.fetchError != null) {
        AppFeedback.showSnackBar(context, _repo.fetchError!, isError: true);
        if (mounted) setState(() {});
        return;
      }

      if (mounted) setState(() {});
      AppFeedback.showSnackBar(context, '查询并缓存成功');
    } catch (e) {
      String errMsg = '未知错误';
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('登录失败')) {
        errMsg = e.toString();
      } else if (errStr.contains('timeout')) {
        errMsg = '网络请求超时';
      } else if (errStr.contains('connection')) {
        errMsg = '网络连接失败';
      } else if (errStr.contains('500') || errStr.contains('502')) {
        errMsg = '学校服务器响应异常';
      }
      AppFeedback.showSnackBar(context, '查询失败: $errMsg', isError: true);
    } finally {
      _stopMessageRotation();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _switchYear(String year) async {
    if (!_repo.hasLiveSession) {
      AppFeedback.showSnackBar(context, '会话已过期，请重新登录', isError: true);
      return;
    }
    await _repo.fetchYearlySummary(year);
    if (_repo.yearlyError != null && mounted) {
      AppFeedback.showSnackBar(context, _repo.yearlyError!, isError: true);
    }
    if (mounted) setState(() {});
  }

  void _updateMessage(String msg) {
    if (mounted) setState(() => _loadingMessage = msg);
  }

  int _msgIdx = 0;

  void _startMessageRotation() {
    _msgIdx = 0;
    Future.doWhile(() async {
      if (!_isLoading || !mounted) return false;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!_isLoading || !mounted) return false;
      _msgIdx = (_msgIdx + 1) % _loadingMessages.length;
      if (mounted) setState(() => _loadingMessage = _loadingMessages[_msgIdx]);
      return _isLoading && mounted;
    });
  }

  void _stopMessageRotation() {
    _isLoading = false;
  }

  // ==================================================================
  //  Build
  // ==================================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('二课成绩查询'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_repo.hasCachedData)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'relogin') {
                  await _repo.clearAll();
                  setState(() {});
                } else if (value == 'clear_cache') {
                  await _repo.clearAll();
                  if (context.mounted) {
                    AppFeedback.showSnackBar(context, '本地缓存已清除');
                    setState(() {});
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'relogin', child: Text('重新登录')),
                const PopupMenuItem(
                    value: 'clear_cache', child: Text('清除本地缓存')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: _repo.hasCachedData ? _buildDataView(isDark) : _buildLoginForm(),
      ),
    );
  }

  // ==================================================================
  //  Login Form (保留原有风格)
  // ==================================================================

  Widget _buildLoginForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final studentId =
        _studentIdCtrl.text.isNotEmpty ? _studentIdCtrl.text : '未登录';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        children: [
          GlassContainer(
            padding: const EdgeInsets.all(16),
            borderRadius: 16,
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '学号 $studentId 已自动识别，请完成双重密码验证',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassContainer(
            padding: const EdgeInsets.all(20),
            borderRadius: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.security, color: Colors.blue, size: 22),
                  const SizedBox(width: 10),
                  const Text('1. 统一认证密码',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('VPN 穿透专用',
                      style: TextStyle(
                          fontSize: 10,
                          color: isDark ? Colors.white38 : Colors.grey[500])),
                ]),
                const SizedBox(height: 16),
                TextField(
                  controller: _casPwdCtrl,
                  onChanged: _onCasPwdChanged,
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
                        : Colors.black.withValues(alpha: 0.03),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassContainer(
            padding: const EdgeInsets.all(20),
            borderRadius: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.school, color: Colors.green, size: 22),
                  const SizedBox(width: 10),
                  const Text('2. 二课查询密码',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('系统登录专用',
                      style: TextStyle(
                          fontSize: 10,
                          color: isDark ? Colors.white38 : Colors.grey[500])),
                ]),
                const SizedBox(height: 16),
                TextField(
                  controller: _erkePwdCtrl,
                  onChanged: _onErkePwdChanged,
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
                        : Colors.black.withValues(alpha: 0.03),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
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
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: _isLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('查询中...',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    )
                  : const Text('开始查询',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          if (_isLoading && _loadingMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_loadingMessage,
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                    fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 30),
          Text('提示：系统将自动完成 WebVPN 穿透，在校外也可无障碍查询成绩。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : Colors.grey[500])),
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
            color: selected ? const Color(0xFF6366F1) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected
                  ? Colors.white
                  : isDark
                      ? Colors.white54
                      : const Color(0xFF8A8F9C),
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
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('分类完成情况',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF20232A))),
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
    final isComplete = grad.totalGap <= 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('毕业完成进度',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF20232A))),
              const Spacer(),
              Text('${percentage.toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6366F1))),
            ],
          ),
          const SizedBox(height: 12),
          // 分数
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                  grad.earnedTotal.toStringAsFixed(
                      grad.earnedTotal == grad.earnedTotal.roundToDouble()
                          ? 0
                          : 1),
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF20232A))),
              Text(' / ${grad.requiredTotal.toStringAsFixed(0)}',
                  style:
                      const TextStyle(fontSize: 18, color: Color(0xFF8A8F9C))),
            ],
          ),
          const SizedBox(height: 10),
          // 进度条
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percentage / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : const Color(0xFFEEF0F4),
              valueColor: AlwaysStoppedAnimation<Color>(
                  isComplete ? Color(0xFF42B36F) : Color(0xFF6366F1)),
            ),
          ),
          const SizedBox(height: 12),
          // 差距信息
          Row(
            children: [
              if (grad.totalGap > 0) ...[
                _infoTag('总分还差 ${grad.totalGap.toStringAsFixed(1)}',
                    isComplete ? Colors.green : Colors.orange),
                const SizedBox(width: 12),
              ] else ...[
                _infoTag('总分已达标 ✓', Colors.green),
                const SizedBox(width: 12),
              ],
              if (grad.unmetCount > 0)
                _infoTag('分类未达标 ${grad.unmetCount} 项', Colors.orange)
              else
                _infoTag('全部分类已达标', Colors.green),
            ],
          ),
          if (grad.unmetCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              grad.categories
                  .where((c) => !c.meetsNumerically)
                  .map((c) => '${c.name}差${c.gap.toStringAsFixed(1)}')
                  .join(' · '),
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F9C)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGraduationCategoryList(ErkeGraduationSummary grad, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(16),
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
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFEEF0F4)),
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
            child: Text(cat.name,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF20232A))),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isOk
                  ? const Color(0xFF42B36F).withValues(alpha: 0.12)
                  : const Color(0xFFF3A640).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              isOk ? '已完成' : '差 ${cat.gap.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isOk ? const Color(0xFF42B36F) : const Color(0xFFF3A640),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${cat.earned.toStringAsFixed(cat.earned == cat.earned.roundToDouble() ? 0 : 1)} / ${cat.required.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF8A8F9C)),
          ),
        ],
      ),
    );
  }

  // ---- 官方结论 ----

  Widget _buildConclusionCard(String conclusion, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1E2433)
            : const Color(0xFF6366F1).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Color(0xFF6366F1)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('官方结论：$conclusion',
                style: const TextStyle(fontSize: 13, color: Color(0xFF20232A))),
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
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('本学年分类情况',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF20232A))),
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
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Text('学年',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF20232A))),
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
                    color: isDark ? Colors.white : const Color(0xFF20232A)),
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
                child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }

  Widget _buildYearlyProgressCard(ErkeYearlySummary yr, bool isDark) {
    final percentage = yr.percentage;
    final isComplete = yr.yearGap <= 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('本学年完成进度',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF20232A))),
            const Spacer(),
            Text('${percentage.toStringAsFixed(1)}%',
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF6366F1))),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
                yr.yearEarnedTotal.toStringAsFixed(
                    yr.yearEarnedTotal == yr.yearEarnedTotal.roundToDouble()
                        ? 0
                        : 1),
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF20232A))),
            Text(' / ${yr.requiredTotal.toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 18, color: Color(0xFF8A8F9C))),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percentage / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : const Color(0xFFEEF0F4),
              valueColor: AlwaysStoppedAnimation<Color>(
                  isComplete ? Color(0xFF42B36F) : Color(0xFF6366F1)),
            ),
          ),
          const SizedBox(height: 12),
          if (yr.yearGap > 0)
            _infoTag('本学年总分还差 ${yr.yearGap.toStringAsFixed(2)}', Colors.orange)
          else
            _infoTag('本学年总分已达标 ✓', Colors.green),
          const SizedBox(height: 8),
          Text('累计总分 ${yr.cumulativeTotal.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF8A8F9C))),
        ],
      ),
    );
  }

  Widget _buildYearlyCategoryList(ErkeYearlySummary yr, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2433) : Colors.white,
        borderRadius: BorderRadius.circular(16),
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
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFEEF0F4)),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildYearlyCategoryRow(ErkeYearlyCategory cat, bool isDark) {
    final isOk = cat.meetsNumerically;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行：名称 + 状态
          Row(children: [
            Expanded(
              child: Text(cat.name,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF20232A))),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isOk
                    ? const Color(0xFF42B36F).withValues(alpha: 0.12)
                    : const Color(0xFFF3A640).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                isOk ? '已完成' : '未达标',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color:
                      isOk ? const Color(0xFF42B36F) : const Color(0xFFF3A640),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          // 第二行：本学年得分 + 累计
          Row(children: [
            Text(
              '本学年 ${cat.yearEarned.toStringAsFixed(cat.yearEarned == cat.yearEarned.roundToDouble() ? 0 : 1)} / 要求 ${cat.required.toStringAsFixed(0)}',
              style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF6366F1)),
            ),
            const Spacer(),
            Text(
              '累计 ${cat.cumulative.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F9C)),
            ),
          ]),
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
        Row(children: [
          Text('$title ${filtered.length}',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF20232A))),
          const Spacer(),
          if (categories.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _showFilterSheet(context, categories),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white10 : const Color(0xFFF0F1F5),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('筛选',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? Colors.white70
                              : const Color(0xFF5C6273))),
                  const SizedBox(width: 4),
                  Icon(Icons.filter_list,
                      size: 16,
                      color: isDark ? Colors.white70 : const Color(0xFF5C6273)),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
                child: Text('该分类暂无数据',
                    style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.grey[600]))),
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
          ? Colors.grey[900]
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('选择分类',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold))),
              ListTile(
                  title: const Text('全部'),
                  trailing: _filterCategory == null
                      ? const Icon(Icons.check, color: Color(0xFF6366F1))
                      : null,
                  onTap: () {
                    setState(() => _filterCategory = null);
                    Navigator.pop(context);
                  }),
              ...categories.map((c) => ListTile(
                  title: Text(c),
                  trailing: _filterCategory == c
                      ? const Icon(Icons.check, color: Color(0xFF6366F1))
                      : null,
                  onTap: () {
                    setState(() => _filterCategory = c);
                    Navigator.pop(context);
                  })),
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
          color: isDark ? const Color(0xFF1E2433) : Colors.white,
          borderRadius: BorderRadius.circular(16),
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
                    child: Text(item.item,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            height: 1.35,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF20232A)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    if (item.category.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(item.category,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF6366F1))),
                      ),
                    Expanded(
                        child: Text(formattedDate,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8A8F9C)))),
                  ]),
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Text('+${item.score}',
                  style: const TextStyle(
                      color: Color(0xFF42B36F),
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
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
            Icon(Icons.cloud_download_outlined,
                size: 48,
                color: isDark ? Colors.white38 : const Color(0xFFB5B8C2)),
            const SizedBox(height: 16),
            Text(
              '检测到旧版二课缓存',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF20232A)),
            ),
            const SizedBox(height: 8),
            Text(
              '需要重新验证账号以获取$mode和学年要求。\n已有活动记录已保留，不会丢失。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF8A8F9C)),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _queryScores,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
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
                                  color: Colors.white, strokeWidth: 2)),
                          SizedBox(width: 10),
                          Text('验证中...', style: TextStyle(fontSize: 15)),
                        ],
                      )
                    : const Text('重新登录并补全数据',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 标签 ----

  Widget _infoTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
