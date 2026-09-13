import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../widgets/app_page_app_bar.dart';

class CourtScreen extends StatefulWidget {
  final int appealId;
  const CourtScreen({super.key, required this.appealId});

  @override
  State<CourtScreen> createState() => _CourtScreenState();
}

class _CourtScreenState extends State<CourtScreen> {
  Map<String, dynamic>? _appeal;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await getSharedDio().get('/appeals/${widget.appealId}');
      final data = response.data;
      final raw = data is Map && data['appeal'] is Map ? data['appeal'] : data;
      if (mounted) {
        setState(
            () => _appeal = raw is Map ? Map<String, dynamic>.from(raw) : null);
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(() => _error = error.response?.data is Map
            ? (error.response?.data['error']?.toString() ?? '申诉详情加载失败')
            : '申诉详情加载失败');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '申诉详情加载失败');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _vote(String vote) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await getSharedDio()
          .post('/appeals/${widget.appealId}/vote', data: {'vote': vote});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(vote == 'support' ? '已投支持票' : '已投反对票')));
      }
      await _load();
    } on DioException catch (error) {
      if (mounted) {
        final message = error.response?.data is Map
            ? error.response?.data['error']?.toString()
            : null;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message ?? '投票失败')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appeal = _appeal;
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公众法庭')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(_error!)))
              : appeal == null
                  ? const Center(child: Text('申诉不存在'))
                  : _content(appeal),
    );
  }

  Widget _content(Map<String, dynamic> appeal) {
    final status = appeal['status']?.toString() ?? 'pending';
    final myVote = appeal['my_vote']?.toString();
    final canVote = appeal['can_vote'] == true && status == 'pending';
    final post = appeal['post'] is Map
        ? Map<String, dynamic>.from(appeal['post'])
        : const <String, dynamic>{};
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('案件 #${appeal['id'] ?? widget.appealId}',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(_status(status)),
        const SizedBox(height: 20),
        _EvidenceSection(
            title: '原内容快照',
            content:
                '${post['title'] ?? '未提供标题'}\n\n${post['content'] ?? '未提供内容'}'),
        _EvidenceSection(
            title: '申诉理由',
            content: (appeal['appellant_reason'] ?? '未填写').toString()),
        _EvidenceSection(
            title: '原治理理由',
            content: (appeal['admin_reason'] ?? '暂无处理理由').toString()),
        if (status != 'pending')
          _EvidenceSection(
              title: '社区复核结果',
              content: (appeal['result'] ?? _status(status)).toString()),
        if ((appeal['support_count'] ?? 0) != 0 ||
            (appeal['oppose_count'] ?? 0) != 0)
          Text(
              '支持申诉 ${appeal['support_count'] ?? 0} · 维持处理 ${appeal['oppose_count'] ?? 0}'),
        if (myVote != null && myVote.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('你的陪审意见：${myVote == 'support' ? '支持申诉' : '维持原处理'}')),
        const SizedBox(height: 24),
        if (canVote)
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: _submitting ? null : () => _vote('support'),
                    icon: const Icon(Icons.check),
                    label: const Text('支持申诉'))),
            const SizedBox(width: 12),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: _submitting ? null : () => _vote('oppose'),
                    icon: const Icon(Icons.close),
                    label: const Text('维持处理'))),
          ])
        else if (status == 'pending')
          const Text('你不是本案陪审员，或已经提交过意见。'),
      ],
    );
  }

  String _status(String status) => switch (status) {
        'pending' => '评议中',
        'pass' => '申诉通过',
        'reject' => '维持原处理',
        'review_required' => '待人工复核',
        _ => status,
      };
}

class _EvidenceSection extends StatelessWidget {
  final String title;
  final String content;
  const _EvidenceSection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(content),
        ]),
      );
}
