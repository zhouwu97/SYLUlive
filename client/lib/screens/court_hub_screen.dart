import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../widgets/app_page_app_bar.dart';
import 'court_screen.dart';

/// 公众法庭入口：列表优先，申诉编号仅作为详情标识，不再是主流程。
class CourtHubScreen extends StatefulWidget {
  final int initialTab;
  const CourtHubScreen({super.key, this.initialTab = 0});

  @override
  State<CourtHubScreen> createState() => _CourtHubScreenState();
}

class _CourtHubScreenState extends State<CourtHubScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _appeals = const [];
  List<Map<String, dynamic>> _publicAppeals = const [];
  late int _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 3).toInt();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await getSharedDio().get('/appeals');
      final data = response.data;
      final raw = data is List
          ? data
          : data is Map && data['appeals'] is List
              ? data['appeals'] as List
              : const <dynamic>[];
      if (!mounted) return;
      setState(() {
        _appeals = raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      });
      try {
        final publicResponse = await getSharedDio().get('/appeals/public');
        final publicData = publicResponse.data;
        if (mounted && publicData is List) {
          setState(() {
            _publicAppeals = publicData.whereType<Map>().map((item) {
              final value = Map<String, dynamic>.from(item);
              value['post'] = {'title': value['post_title'] ?? '社区治理复核'};
              return value;
            }).toList();
          });
        }
      } catch (_) {
        // 公示失败不影响个人案件列表。
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(() => _error = error.response?.data is Map
            ? (error.response?.data['error']?.toString() ?? '案件列表加载失败')
            : '案件列表加载失败');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '案件列表加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _visibleAppeals {
    if (_tab == 3) return _publicAppeals;
    return _appeals.where((appeal) {
      final status = appeal['status']?.toString() ?? 'pending';
      return switch (_tab) {
        0 => appeal['can_vote'] == true && status == 'pending',
        1 => appeal['is_appellant'] == true,
        2 => appeal['my_vote'] != null && appeal['my_vote'] != '',
        _ => true,
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _appeals
        .where((appeal) =>
            appeal['can_vote'] == true && appeal['status'] == 'pending')
        .length;
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公众法庭')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text('社区自治', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('公平复核每一次有争议的治理决定',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            _summaryRow(pendingCount),
            const SizedBox(height: 16),
            _CourtTabs(
              selected: _tab,
              onChanged: (value) => setState(() => _tab = value),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              _ErrorState(message: _error!, onRetry: _load)
            else if (_visibleAppeals.isEmpty)
              _EmptyCourtState(tab: _tab)
            else
              ..._visibleAppeals.map(_buildAppealTile),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(int pendingCount) {
    return Row(
      children: [
        _SummaryItem(label: '待我陪审', value: _loading ? '—' : '$pendingCount'),
        const SizedBox(width: 8),
        _SummaryItem(
            label: '我的申诉',
            value: _loading
                ? '—'
                : '${_appeals.where((item) => item['is_appellant'] == true).length}'),
        const SizedBox(width: 8),
        _SummaryItem(
            label: '已参与',
            value: _loading
                ? '—'
                : '${_appeals.where((item) => item['my_vote'] != null && item['my_vote'] != '').length}'),
      ],
    );
  }

  Widget _buildAppealTile(Map<String, dynamic> appeal) {
    final id = appeal['id'];
    final status = appeal['status']?.toString() ?? 'pending';
    final post = appeal['post'] is Map
        ? Map<String, dynamic>.from(appeal['post'])
        : const <String, dynamic>{};
    final canVote = appeal['can_vote'] == true;
    final isPublic = _tab == 3;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
            child: Icon(
                canVote ? Icons.how_to_vote_outlined : Icons.gavel_outlined)),
        title: Text('案件 #$id · ${_status(status)}'),
        subtitle: Text(
          (post['title'] ?? '社区帖子治理复核').toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: id is num && !isPublic
            ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => CourtScreen(appealId: id.toInt())))
                .then((_) => _load())
            : isPublic
                ? () => _showPublicResult(appeal)
                : null,
      ),
    );
  }

  Future<void> _showPublicResult(Map<String, dynamic> appeal) async {
    final isManual = appeal['resolution_source'] == 'manual_review';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('案件 #${appeal['id']} · 已结案'),
        content: Text(
            '${appeal['result'] ?? '社区复核已完成'}\n\n支持申诉 ${appeal['support_count'] ?? 0} · 维持处理 ${appeal['oppose_count'] ?? 0}\n\n${isManual ? '社区评议未达到法定人数，以上票数仅作评议记录；最终由独立管理员复核。' : '陪审员身份不公开。'}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('知道了'))
        ],
      ),
    );
  }

  String _status(String status) => switch (status) {
        'pending' => '评议中',
        'pass' => '申诉通过',
        'reject' => '维持处理',
        'review_required' => '待人工复核',
        _ => status,
      };
}

class _CourtTabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;

  const _CourtTabs({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final labels = ['待陪审', '我的申诉', '参与记录', '结案公示'];
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(22),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++)
            Expanded(
              child: InkWell(
                onTap: () => onChanged(index),
                child: Container(
                  alignment: Alignment.center,
                  color: selected == index ? scheme.primaryContainer : null,
                  child: Text(
                    labels[index],
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: selected == index
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                          fontWeight:
                              selected == index ? FontWeight.w700 : null,
                        ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyCourtState extends StatelessWidget {
  final int tab;
  const _EmptyCourtState({required this.tab});

  @override
  Widget build(BuildContext context) {
    final isJury = tab == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 42, 24, 24),
      child: Column(
        children: [
          Icon(isJury ? Icons.balance_outlined : Icons.gavel_outlined,
              size: 40, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(isJury ? '暂时没有待你陪审的案件' : '这里还没有案件记录',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(isJury ? '当你被随机选为陪审员后，案件会出现在这里。' : '你的申诉和参与记录会在案件创建后显示。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(label)
        ]),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
          child: Column(children: [
        Text(message),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onRetry, child: const Text('重试'))
      ]));
}
