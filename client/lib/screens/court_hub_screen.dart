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
    return _appeals.where((appeal) {
      final status = appeal['status']?.toString() ?? 'pending';
      return switch (_tab) {
        1 => appeal['can_vote'] == true && status == 'pending',
        2 => appeal['is_appellant'] == true || appeal['is_admin'] == true,
        _ => _tab == 3 ? status != 'pending' : true,
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
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('全部')),
                ButtonSegment(value: 1, label: Text('待我陪审')),
                ButtonSegment(value: 2, label: Text('我的案件')),
                ButtonSegment(value: 3, label: Text('结案公示')),
              ],
              selected: {_tab},
              onSelectionChanged: (value) => setState(() => _tab = value.first),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              _ErrorState(message: _error!, onRetry: _load)
            else if (_visibleAppeals.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('暂无相关案件')))
            else
              ..._visibleAppeals.map(_buildAppealTile),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(int pendingCount) {
    final closedCount =
        _appeals.where((item) => item['status'] != 'pending').length;
    return Row(
      children: [
        _SummaryItem(label: '待我陪审', value: '$pendingCount'),
        const SizedBox(width: 8),
        _SummaryItem(
            label: '我的案件',
            value:
                '${_appeals.where((item) => item['is_appellant'] == true || item['is_admin'] == true).length}'),
        const SizedBox(width: 8),
        _SummaryItem(label: '已结案', value: '$closedCount'),
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
        onTap: id is num
            ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => CourtScreen(appealId: id.toInt())))
                .then((_) => _load())
            : null,
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
