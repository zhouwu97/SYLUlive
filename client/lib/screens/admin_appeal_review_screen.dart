import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../widgets/app_page_app_bar.dart';

/// 管理员处理陪审人数不足、平票等 review_required 案件。
class AdminAppealReviewScreen extends StatefulWidget {
  const AdminAppealReviewScreen({super.key});

  @override
  State<AdminAppealReviewScreen> createState() =>
      _AdminAppealReviewScreenState();
}

class _AdminAppealReviewScreenState extends State<AdminAppealReviewScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await getSharedDio().get('/admin/appeals/review');
      final data = response.data;
      final raw = data is List
          ? data
          : data is Map && data['appeals'] is List
              ? data['appeals'] as List
              : const <dynamic>[];
      if (mounted) {
        setState(() => _items = raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList());
      }
    } on DioException catch (error) {
      if (mounted) {
        setState(() => _error = error.response?.data is Map
            ? (error.response?.data['error']?.toString() ?? '待复核案件加载失败')
            : '待复核案件加载失败');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '待复核案件加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve(Map<String, dynamic> appeal, String decision) async {
    final reason = await _askReason(decision);
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await getSharedDio().post('/admin/appeals/${appeal['id']}/review', data: {
        'decision': decision,
        'reason': reason.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('人工复核已完成')));
      _load();
    } on DioException catch (error) {
      if (!mounted) return;
      final message = error.response?.data is Map
          ? error.response?.data['error']?.toString()
          : null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message ?? '处理失败')));
    }
  }

  Future<String?> _askReason(String decision) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(decision == 'pass' ? '确认申诉通过' : '确认维持原处理'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '复核理由',
            hintText: '说明你依据的证据和判断',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('提交')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公众法庭复核')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: Text(_error!)))
                : _items.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 180),
                        Center(child: Text('暂无待人工复核案件'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (_, index) => _buildCard(_items[index]),
                      ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> appeal) {
    final post = appeal['post'] is Map
        ? Map<String, dynamic>.from(appeal['post'])
        : const <String, dynamic>{};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('案件 #${appeal['id'] ?? '-'}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text((post['title'] ?? '社区内容').toString(),
              maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Text((appeal['result'] ?? '案件需要人工复核').toString(),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton(
                    onPressed: () => _resolve(appeal, 'pass'),
                    child: const Text('支持申诉'))),
            const SizedBox(width: 10),
            Expanded(
                child: OutlinedButton(
                    onPressed: () => _resolve(appeal, 'reject'),
                    child: const Text('维持处理'))),
          ]),
        ]),
      ),
    );
  }
}
