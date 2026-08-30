import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../models/competition_award.dart';
import '../../utils/app_feedback.dart';
import '../../services/async_action_guard.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import '../../services/idempotency_key.dart';

class CompetitionAwardVerificationAdminScreen extends StatefulWidget {
  final Dio dio;

  const CompetitionAwardVerificationAdminScreen({
    super.key,
    required this.dio,
  });

  @override
  State<CompetitionAwardVerificationAdminScreen> createState() =>
      _CompetitionAwardVerificationAdminScreenState();
}

class _CompetitionAwardVerificationAdminScreenState
    extends State<CompetitionAwardVerificationAdminScreen> {
  final _searchController = TextEditingController();
  List<_VerificationSummary> _items = const [];
  String _status = 'pending';
  bool _loading = true;
  String? _error;
  int _page = 1;
  int _total = 0;
  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final response = await widget.dio.get(
        '/admin/competition-awards/verifications',
        queryParameters: {
          'status': _status,
          'page': _page,
          'page_size': _pageSize,
          if (_searchController.text.trim().isNotEmpty)
            'keyword': _searchController.text.trim(),
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() {
        _items = ((data['items'] as List?) ?? const [])
            .map((item) => _VerificationSummary.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList();
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '核验列表加载失败')
            : '核验列表加载失败';
      });
    }
  }

  Future<void> _open(_VerificationSummary summary) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CompetitionAwardVerificationDetailScreen(
          dio: widget.dio,
          awardId: summary.id,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalPages = (_total / _pageSize).ceil().clamp(1, 999999);
    return Scaffold(
      backgroundColor: CompetitionUiTokens.pageBg(isDark),
      appBar: AppBar(
        title: const Text('经历核验'),
        backgroundColor: CompetitionUiTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            TextField(
              key: const Key('award-verification-search'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                setState(() => _page = 1);
                _load();
              },
              decoration: InputDecoration(
                hintText: '搜索用户、比赛或奖项',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () {
                    setState(() => _page = 1);
                    _load();
                  },
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              key: const Key('award-verification-filter'),
              segments: const [
                ButtonSegment(value: 'pending', label: Text('待核验')),
                ButtonSegment(value: 'verified', label: Text('已核验')),
                ButtonSegment(value: 'rejected', label: Text('未通过')),
              ],
              selected: {_status},
              showSelectedIcon: false,
              onSelectionChanged: (values) {
                setState(() {
                  _status = values.first;
                  _page = 1;
                });
                _load();
              },
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _message(isDark, _error!, '重新加载', _load)
            else if (_items.isEmpty)
              _message(isDark, '当前筛选下没有核验记录', null, null)
            else
              ..._items.map((item) => _card(item, isDark)),
            if (!_loading && _error == null && _total > _pageSize) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: _page <= 1
                        ? null
                        : () {
                            setState(() => _page--);
                            _load();
                          },
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  SizedBox(
                    width: 88,
                    child: Text(
                      '$_page / $totalPages',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: _page >= totalPages
                        ? null
                        : () {
                            setState(() => _page++);
                            _load();
                          },
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card(_VerificationSummary item, bool isDark) {
    final status = competitionAwardStatusLabels[item.verificationStatus] ??
        item.verificationStatus;
    final result = [item.awardLevel, item.awardName]
        .where((value) => value.trim().isNotEmpty)
        .join(' · ');
    return Container(
      key: Key('award-verification-${item.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          onTap: () => _open(item),
          title: Text(
            item.competitionTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${item.userNickname} · ${item.competitionYear}\n$result · $status · ${item.evidenceCount} 份材料',
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }

  Widget _message(bool isDark, String text, String? action, VoidCallback? tap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 52),
      child: Column(
        children: [
          Icon(Icons.fact_check_outlined,
              size: 42, color: CompetitionUiTokens.subColor(isDark)),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (action != null && tap != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: tap, child: Text(action)),
          ],
        ],
      ),
    );
  }
}

class CompetitionAwardVerificationDetailScreen extends StatefulWidget {
  final Dio dio;
  final int awardId;

  const CompetitionAwardVerificationDetailScreen({
    super.key,
    required this.dio,
    required this.awardId,
  });

  @override
  State<CompetitionAwardVerificationDetailScreen> createState() =>
      _CompetitionAwardVerificationDetailScreenState();
}

class _CompetitionAwardVerificationDetailScreenState
    extends State<CompetitionAwardVerificationDetailScreen> {
  CompetitionAward? _award;
  String _nickname = '';
  bool _loading = true;
  bool _submitting = false;
  final AsyncActionGuard _actionGuard = AsyncActionGuard();
  String? _verificationIdempotencyKey;
  String? _verificationIdempotencyFingerprint;
  final Set<int> _loadingEvidence = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await widget.dio
          .get('/admin/competition-awards/verifications/${widget.awardId}');
      final data = Map<String, dynamic>.from(response.data as Map);
      final awardData = Map<String, dynamic>.from(data['award'] as Map);
      if (!mounted) return;
      setState(() {
        _award = CompetitionAward.fromJson(awardData);
        _nickname = '${awardData['user_nickname'] ?? ''}';
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '核验详情加载失败')
            : '核验详情加载失败';
      });
    }
  }

  Future<void> _showEvidence(int fileId) async {
    if (_loadingEvidence.contains(fileId)) return;
    setState(() => _loadingEvidence.add(fileId));
    try {
      final response = await widget.dio.get<List<int>>(
        '/admin/competition-awards/verifications/${widget.awardId}/evidence/$fileId',
        options: Options(responseType: ResponseType.bytes),
      );
      if (!mounted) return;
      final bytes = Uint8List.fromList(response.data ?? const []);
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: InteractiveViewer(
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '材料读取失败')
              : '材料读取失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingEvidence.remove(fileId));
    }
  }

  Future<void> _review({required bool approve}) async {
    if (_submitting || _award?.verificationStatus != 'pending') return;
    var note = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? '确认通过材料核验？' : '驳回材料核验？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(approve ? '仅确认材料与填写信息一致，不代表学校或教务认证。' : '请明确说明材料不足或信息不一致之处。'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('award-verification-note'),
              maxLength: 500,
              maxLines: 4,
              onChanged: (value) => note = value.trim(),
              decoration: InputDecoration(
                labelText: approve ? '核验说明（选填）' : '驳回原因',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!approve && note.isEmpty) return;
              Navigator.pop(context, true);
            },
            child: Text(approve ? '确认通过' : '确认驳回'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _actionGuard.run<void>(
      'award-verification:${widget.awardId}:$approve',
      () => _reviewOnce(approve: approve, note: note),
    );
  }

  Future<void> _reviewOnce(
      {required bool approve, required String note}) async {
    final fingerprint = '$approve:$note';
    if (_verificationIdempotencyFingerprint != fingerprint) {
      _verificationIdempotencyFingerprint = fingerprint;
      _verificationIdempotencyKey = null;
    }
    setState(() => _submitting = true);
    try {
      await widget.dio.post(
        '/admin/competition-awards/verifications/${widget.awardId}/${approve ? 'approve' : 'reject'}',
        data: approve ? {'note': note} : {'reason': note},
        options: Options(headers: <String, dynamic>{
          'Idempotency-Key': _verificationIdempotencyKey ??=
              newIdempotencyKey('award-verification'),
        }),
      );
      _verificationIdempotencyKey = null;
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '保存核验结果失败')
              : '保存核验结果失败',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: CompetitionUiTokens.pageBg(isDark),
      appBar: AppBar(
        title: const Text('核验详情'),
        backgroundColor: CompetitionUiTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _content(isDark),
      bottomNavigationBar:
          _award?.verificationStatus == 'pending' ? _actions() : null,
    );
  }

  Widget _content(bool isDark) {
    final award = _award!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: CompetitionUiTokens.cardDecoration(isDark),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(award.competitionTitle,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text('用户：$_nickname'),
              Text('年份：${award.competitionYear}'),
              Text('奖项：${award.awardLevel} ${award.awardName}'.trim()),
              Text('赛道：${award.trackName.isEmpty ? '未填写' : award.trackName}'),
              Text(
                  '角色：${competitionAwardRoleLabels[award.role] ?? award.role}'),
              const SizedBox(height: 10),
              Text(award.contributionSummary.isEmpty
                  ? '未填写贡献描述'
                  : award.contributionSummary),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('证明材料（${award.evidenceFileIds.length}）',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...award.evidenceFileIds.asMap().entries.map(
              (entry) => ListTile(
                key: Key('award-evidence-${entry.value}'),
                onTap: _loadingEvidence.contains(entry.value)
                    ? null
                    : () => _showEvidence(entry.value),
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text('材料 ${entry.key + 1}'),
                subtitle: const Text('点击后按需读取，访问行为会记录'),
                trailing: _loadingEvidence.contains(entry.value)
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.visibility_outlined),
              ),
            ),
      ],
    );
  }

  Widget _actions() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('award-verification-reject'),
                onPressed: _submitting ? null : () => _review(approve: false),
                icon: const Icon(Icons.close_rounded),
                label: const Text('驳回'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('award-verification-approve'),
                onPressed: _submitting ? null : () => _review(approve: true),
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('通过'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerificationSummary {
  final int id;
  final String userNickname;
  final String competitionTitle;
  final int competitionYear;
  final String awardName;
  final String awardLevel;
  final String verificationStatus;
  final int evidenceCount;

  const _VerificationSummary({
    required this.id,
    required this.userNickname,
    required this.competitionTitle,
    required this.competitionYear,
    required this.awardName,
    required this.awardLevel,
    required this.verificationStatus,
    required this.evidenceCount,
  });

  factory _VerificationSummary.fromJson(Map<String, dynamic> json) {
    return _VerificationSummary(
      id: (json['id'] as num?)?.toInt() ?? 0,
      userNickname: '${json['user_nickname'] ?? ''}',
      competitionTitle: '${json['competition_title'] ?? ''}',
      competitionYear: (json['competition_year'] as num?)?.toInt() ?? 0,
      awardName: '${json['award_name'] ?? ''}',
      awardLevel: '${json['award_level'] ?? ''}',
      verificationStatus: '${json['verification_status'] ?? ''}',
      evidenceCount: (json['evidence_count'] as num?)?.toInt() ?? 0,
    );
  }
}
