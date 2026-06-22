import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';
import '../features/campus_data/common/campus_http_session.dart';
import '../features/campus_data/erke/erke_repository.dart';
import '../features/campus_data/erke/erke_models.dart';
import '../features/campus_data/storage/campus_secure_store.dart';
import '../features/campus_data/storage/erke_cache_store.dart';

class ErkeScoreScreen extends StatefulWidget {
  const ErkeScoreScreen({super.key});

  @override
  State<ErkeScoreScreen> createState() => _ErkeScoreScreenState();
}

class _ErkeScoreScreenState extends State<ErkeScoreScreen> {
  final _casPwdCtrl = TextEditingController();
  final _erkePwdCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();

  late final ErkeRepository _repository;
  late final CampusHttpSession _session;
  late final CampusSecureStore _secureStore;
  late final ErkeCacheStore _cacheStore;

  bool _obscureCas = true;
  bool _obscureErke = true;
  String? _filterCategory;
  
  String _realCasPwd = '';
  String _realErkePwd = '';

  static const _loadingMessages = [
    '姝ｅ湪绌块€忓鏍″唴缃戯紝璇风◢鍊欌€?,
    '姝ｅ湪閫氳繃缁熶竴璁よ瘉鈥?,
    '姝ｅ湪杩涘叆浜岃骞冲彴鈥?,
    '姝ｅ湪鎶撳彇鎴愮哗鏁版嵁鈥?,
  ];

  @override
  void initState() {
    super.initState();
    _session = CampusHttpSession();
    _secureStore = CampusSecureStore();
    _cacheStore = ErkeCacheStore();
    
    _repository = ErkeRepository(
      session: _session,
      secureStore: _secureStore,
      cacheStore: _cacheStore,
    );
    _repository.addListener(_onRepositoryUpdated);

    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _studentIdCtrl.text = user.studentId;
    }
    _initStorage();
  }

  void _onRepositoryUpdated() {
    if (mounted) setState(() {});
  }

  Future<void> _initStorage() async {
    await _cacheStore.init();
    await _secureStore.migrateOldPasswords();
    await _loadSavedPasswords();

    if (_repository.summary != null && mounted) {
      setState(() {});
    }
  }

  // Cache is handled by ErkeRepository

  Future<void> _loadSavedPasswords() async {
    try {
      final casPwd = await _secureStore.getWebvpnPassword() ?? '';
      final erkePwd = await _secureStore.getErkePassword() ?? '';

      _realCasPwd = casPwd;
      _realErkePwd = erkePwd;

      _casPwdCtrl.text = casPwd.isEmpty ? '' : '鈥? * casPwd.length;
      _erkePwdCtrl.text = erkePwd.isEmpty ? '' : '鈥? * erkePwd.length;

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _onCasPwdChanged(String val) {
    final placeholder = '鈥? * _realCasPwd.length;
    if (_realCasPwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('鈥?, '');
      _realCasPwd = '';
      _casPwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  void _onErkePwdChanged(String val) {
    final placeholder = '鈥? * _realErkePwd.length;
    if (_realErkePwd.isNotEmpty && val != placeholder) {
      final newText = val.replaceAll('鈥?, '');
      _realErkePwd = '';
      _erkePwdCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  Future<void> _savePasswords(String casPwd, String erkePwd) async {
    await _secureStore.saveWebvpnCredentials(_studentIdCtrl.text.trim(), casPwd);
    await _secureStore.saveErkePassword(erkePwd);
  }

  @override
  void dispose() {
    _repository.removeListener(_onRepositoryUpdated);
    _casPwdCtrl.dispose();
    _erkePwdCtrl.dispose();
    _studentIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _queryScores() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.showSnackBar(context, '璇峰厛鍦ㄣ€屾垜鐨勩€嶉〉闈㈢櫥褰曞悗鍐嶆煡璇?, isError: true);
      return;
    }

    final inputCasPwd = _casPwdCtrl.text;
    final inputErkePwd = _erkePwdCtrl.text;
    
    final casPwd = inputCasPwd == ('鈥? * _realCasPwd.length) ? _realCasPwd : inputCasPwd;
    final erkePwd = inputErkePwd == ('鈥? * _realErkePwd.length) ? _realErkePwd : inputErkePwd;
    final studentId = _studentIdCtrl.text.trim();

    if (casPwd.isEmpty || erkePwd.isEmpty || studentId.isEmpty) {
      AppFeedback.showSnackBar(context, '璇峰～鍐欏畬鏁翠俊鎭紝鎴栧厛鐐瑰嚮"鍒囨崲璐﹀彿/淇敼瀵嗙爜"杈撳叆瀵嗙爜');
      return;
    }

    await _repository.loginAndFetch(studentId, casPwd, erkePwd);

    if (mounted) {
      if (_repository.errorMsg != null) {
        AppFeedback.showSnackBar(context, '鏌ヨ澶辫触: ${_repository.errorMsg}', isError: true);
      } else {
        await _secureStore.saveWebvpnCredentials(studentId, casPwd);
        await _secureStore.saveErkePassword(erkePwd);
        AppFeedback.showSnackBar(context, '鏌ヨ鎴愬姛');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('浜岃鎴愮哗鏌ヨ'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (_repository.summary != null)
            TextButton(
              onPressed: _repository.isLoading ? null : _queryScores,
              child: _repository.isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('閲嶆柊鎷夊彇', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _repository.summary == null ? _buildLoginForm() : _buildScoreList(isDark),
            if (_repository.isLoading && _repository.summary != null)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey[850] : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text('姝ｅ湪鏇存柊鏁版嵁...', style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final studentId = _studentIdCtrl.text.isNotEmpty ? _studentIdCtrl.text : '鏈櫥褰?;
    
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
                    '瀛﹀彿 $studentId 宸茶嚜鍔ㄨ瘑鍒紝璇峰畬鎴愬弻閲嶅瘑鐮侀獙璇?,
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
                    const Text('1. 缁熶竴璁よ瘉瀵嗙爜', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('VPN 绌块€忎笓鐢?, style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.grey[500])),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _casPwdCtrl,
                  onChanged: _onCasPwdChanged,
                  obscureText: _obscureCas,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '杈撳叆缁熶竴韬唤璁よ瘉瀵嗙爜',
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
                    const Text('2. 浜岃鏌ヨ瀵嗙爜', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('绯荤粺鐧诲綍涓撶敤', style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.grey[500])),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _erkePwdCtrl,
                  onChanged: _onErkePwdChanged,
                  obscureText: _obscureErke,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '杈撳叆浜岃骞冲彴鐧诲綍瀵嗙爜',
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
              onPressed: _repository.isLoading ? null : _queryScores,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: _repository.isLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('鏌ヨ涓?..', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    )
                  : const Text('寮€濮嬫煡璇?, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          
          if (_repository.isLoading) ...[
            const SizedBox(height: 16),
            Text('姝ｅ湪鏌ヨ浜岃鎴愮哗锛岃鑰愬績绛夊緟...', style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.grey[600], fontStyle: FontStyle.italic)),
          ],
          
          const SizedBox(height: 30),
          Text(
            '鎻愮ず锛氱郴缁熷皢鑷姩瀹屾垚 WebVPN 绌块€忥紝鍦ㄦ牎澶栦篃鍙棤闅滅鏌ヨ鎴愮哗銆?,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreList(bool isDark) {
    final activities = _repository.activities ?? [];
    
    // 鏀堕泦鎵€鏈夌被鍒敤浜庣瓫閫?
    final categoryList = <String>[];
    for (final a in activities) {
      if (a.category.isNotEmpty && !categoryList.contains(a.category)) {
        categoryList.add(a.category);
      }
    }

    // 鎸夌瓫閫夎繃婊?
    final filtered = activities.where((a) {
      if (_filterCategory == null) return true;
      return a.category == _filterCategory;
    }).toList();

    return Column(
      children: [
        if (_repository.summary != null) _buildSummaryHeader(isDark),
        // 绛涢€夋潯
        if (categoryList.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip('鍏ㄩ儴', _filterCategory == null,
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
                '${_filterCategory ?? '鏌ヨ缁撴灉'} (${filtered.length})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  await _repository.logout();
                  setState(() {
                    _filterCategory = null;
                  });
                },
                child: const Text('閫€鍑鸿处鍙?),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text('璇ュ垎绫绘殏鏃犳暟鎹?,
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
    final summary = _repository.summary!;
    final totalScore = summary.total;
    
    final cats = [
      {'name': '鎬濇兂鏀挎不绱犺川涓庨亾寰蜂慨鍏?, 'score': summary.categoryA},
      {'name': '绀句細瀹炶返涓庡織鎰挎湇鍔?, 'score': summary.categoryB},
      {'name': '瀛︽湳绉戞妧涓庡垱鏂板垱涓?, 'score': summary.categoryC},
      {'name': '鏂囧寲鑹烘湳涓庤韩蹇冨彂灞?, 'score': summary.categoryD},
      {'name': '绀惧洟娲诲姩涓庣ぞ浼氬伐浣?, 'score': summary.categoryE},
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 鍒嗙被鍗＄墖妯悜婊氬姩
          SizedBox(
            height: 106,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: cats.length,
              itemBuilder: (context, index) {
                final item = cats[index];
                final score = item['score'] as double;
                final name = item['name'] as String;

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
                          name,
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
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '瀹為檯寰楀垎',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white54 : Colors.grey[700],
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
          // 鎬昏琛?
          GlassContainer(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            borderRadius: 12,
            child: Row(
              children: [
                const Text('鎬昏寰楀垎', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  totalScore.toStringAsFixed(totalScore == totalScore.roundToDouble() ? 0 : 1),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF6366F1)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreItem(ErkeActivity item, bool isDark) {
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
                    item.name,
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
                    '+${item.score}',
                    style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (item.category.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      item.category,
                      style: TextStyle(fontSize: 11, color: Theme.of(context).primaryColor),
                    ),
                  ),
                Expanded(
                  child: Text(
                    item.date,
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
