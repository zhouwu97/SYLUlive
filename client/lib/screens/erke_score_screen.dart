import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/webvpn_service.dart';
import '../utils/sylu_client_crawler.dart';
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

  bool _isLoading = false;
  String _loadingMessage = '';
  List<dynamic>? _scores;
  List<dynamic>? _summary;
  bool _obscureCas = true;
  bool _obscureErke = true;
  String? _filterCategory;
  
  String _realCasPwd = '';
  String _realErkePwd = '';

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
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
    _loadSavedPasswords();
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

  Future<void> _queryScores() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.showSnackBar(context, '请先在「我的」页面登录后再查询', isError: true);
      return;
    }

    final inputCasPwd = _casPwdCtrl.text;
    final inputErkePwd = _erkePwdCtrl.text;
    
    final casPwd = inputCasPwd == ('•' * _realCasPwd.length) ? _realCasPwd : inputCasPwd;
    final erkePwd = inputErkePwd == ('•' * _realErkePwd.length) ? _realErkePwd : inputErkePwd;
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
      final ok = await _vpn.login(studentId, casPwd);
      if (!ok) {
        AppFeedback.showSnackBar(context, '统一认证登录失败，请检查密码', isError: true);
        return;
      }

      _updateMessage('正在进入二课平台…');
      final crawler = SyluClientCrawler(cookieJar: _vpn.cookieJar, dio: _vpn.dio);
      final htmlStr = await crawler.login(studentId, erkePwd, _vpn.vpnCookie);
      final data = crawler.parseErkeData(htmlStr);

      if (data['scores'].isNotEmpty) {
        setState(() {
          _scores = data['scores'];
          _summary = data['summary'];
        });
      } else {
        AppFeedback.showSnackBar(context, '查询成功，但未解析到成绩数据或账号密码错误', isError: true);
      }
    } catch (e) {
      AppFeedback.showSnackBar(context, '查询失败: $e', isError: true);
    } finally {
      _stopMessageRotation();
      if (mounted) setState(() => _isLoading = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('二课成绩查询'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: _scores == null
            ? _buildLoginForm()
            : _buildScoreList(isDark),
      ),
    );
  }

  Widget _buildLoginForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final studentId = _studentIdCtrl.text.isNotEmpty ? _studentIdCtrl.text : '未登录';
    
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
                    style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87),
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
                Row(
                  children: [
                    const Icon(Icons.security, color: Colors.blue, size: 22),
                    const SizedBox(width: 10),
                    const Text('1. 统一认证密码', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('VPN 穿透专用', style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.grey[500])),
                  ],
                ),
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
                      icon: Icon(_obscureCas ? Icons.visibility_off : Icons.visibility, size: 18),
                      onPressed: () => setState(() => _obscureCas = !_obscureCas),
                    ),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
                Row(
                  children: [
                    const Icon(Icons.school, color: Colors.green, size: 22),
                    const SizedBox(width: 10),
                    const Text('2. 二课查询密码', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('系统登录专用', style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.grey[500])),
                  ],
                ),
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
                      icon: Icon(_obscureErke ? Icons.visibility_off : Icons.visibility, size: 18),
                      onPressed: () => setState(() => _obscureErke = !_obscureErke),
                    ),
                    filled: true,
                    fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: _isLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('查询中...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    )
                  : const Text('开始查询', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          
          if (_isLoading && _loadingMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(_loadingMessage, style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600], fontStyle: FontStyle.italic)),
          ],
          
          const SizedBox(height: 30),
          Text(
            '提示：系统将自动完成 WebVPN 穿透，在校外也可无障碍查询成绩。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreList(bool isDark) {
    // 收集所有类别用于筛选，保持与 summary 顺序一致
    final categoryList = <String>[];
    if (_summary != null) {
      for (final item in _summary!) {
        final cat = item['category']?.toString() ?? '';
        if (cat.isNotEmpty && !categoryList.contains(cat)) {
          categoryList.add(cat);
        }
      }
    }
    
    // 如果成绩列表中有 summary 未包含的类别，追加到后面
    if (_scores != null) {
      for (final s in _scores!) {
        final cat = s['category']?.toString() ?? '';
        if (cat.isNotEmpty && !categoryList.contains(cat)) {
          categoryList.add(cat);
        }
      }
    }

    // 按筛选过滤
    final filtered = _scores?.where((s) {
      if (_filterCategory == null) return true;
      return (s['category'] ?? '') == _filterCategory;
    }).toList() ?? [];

    return Column(
      children: [
        if (_summary != null && _summary!.isNotEmpty) _buildSummaryHeader(isDark),
        // 筛选条
        if (categoryList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip('全部', _filterCategory == null,
                      onTap: () => setState(() => _filterCategory = null)),
                  ...categoryList.map((c) => _filterChip(c, _filterCategory == c,
                      onTap: () => setState(() => _filterCategory = c))),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Row(
            children: [
              Text(
                '${_filterCategory ?? '查询结果'} (${filtered.length})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton(onPressed: () => setState(() { _scores = null; _filterCategory = null; }), child: const Text('重新查询')),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text('该分类暂无数据',
                      style: TextStyle(fontSize: 14, color: isDark ? Colors.white54 : Colors.grey[600])))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    return _buildScoreItem(item, isDark);
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, {VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontSize: 13, color: selected ? Colors.white : null)),
        selected: selected,
        selectedColor: const Color(0xFF6366F1),
        backgroundColor: Colors.transparent,
        side: BorderSide(color: selected ? const Color(0xFF6366F1) : Colors.grey.withValues(alpha: 0.3)),
        onSelected: (_) => onTap?.call(),
      ),
    );
  }

  Widget _buildSummaryHeader(bool isDark) {
    double totalScore = 0;
    double totalRequired = 0;
    double totalGap = 0;
    for (final item in _summary!) {
      double score = double.tryParse(item['score'] ?? '0') ?? 0;
      double required = double.tryParse(item['required'] ?? '0') ?? 0;
      totalScore += score;
      totalRequired += required;
      if (required > score) {
        totalGap += (required - score);
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分类卡片横向滚动
          SizedBox(
            height: 106,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _summary!.length,
              itemBuilder: (context, index) {
                final item = _summary![index];
                final score = double.tryParse(item['score'] ?? '0') ?? 0;
                final required = double.tryParse(item['required'] ?? '0') ?? 0;
                final gap = required - score;
                final isFull = gap <= 0;

                return Container(
                  width: 130,
                  margin: const EdgeInsets.only(right: 10),
                  child: GlassContainer(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    borderRadius: 14,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['category'] ?? '',
                          style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              score.toStringAsFixed(score == score.roundToDouble() ? 0 : 1),
                              style: TextStyle(fontSize: 20, color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              ' / $required',
                              style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.grey[500]),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isFull ? '✓ 已完成' : '还差 ${gap.toStringAsFixed(gap == gap.roundToDouble() ? 0 : 1)} 分',
                          style: TextStyle(
                            fontSize: 11,
                            color: isFull ? Colors.green : (isDark ? Colors.white54 : Colors.grey[700]),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          // 总计行
          GlassContainer(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            borderRadius: 12,
            child: Row(
              children: [
                const Text('总计', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  '${totalScore.toStringAsFixed(totalScore == totalScore.roundToDouble() ? 0 : 1)} / $totalRequired',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF6366F1)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: totalGap <= 0 ? Colors.green.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    totalGap <= 0 ? '已完成 ✓' : '还差 ${totalGap.toStringAsFixed(totalGap == totalGap.roundToDouble() ? 0 : 1)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: totalGap <= 0 ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreItem(Map<String, dynamic> item, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
        padding: const EdgeInsets.all(16),
        borderRadius: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item['item'] ?? '未知项目',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '+${item['score']}',
                    style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (item['category'] != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      item['category'],
                      style: TextStyle(fontSize: 11, color: Theme.of(context).primaryColor),
                    ),
                  ),
                Expanded(
                  child: Text(
                    item['date'] ?? '',
                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.grey[600]),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
