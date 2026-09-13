import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_bootstrap.dart';
import '../widgets/app_page_app_bar.dart';
import 'court_screen.dart';

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

  Future<void> _openDetail(Map<String, dynamic> appeal) async {
    final id = (appeal['id'] as num?)?.toInt();
    if (id == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CourtScreen(appealId: id, adminReviewMode: true)),
    );
    if (mounted) _load();
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
    return Card(
      child: InkWell(
        onTap: () => _openDetail(appeal),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('案件 #${appeal['id'] ?? '-'}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('社区内容治理复核'),
            const SizedBox(height: 8),
            Text((appeal['result'] ?? '案件需要人工复核').toString(),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.visibility_outlined,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text('查看匿名证据并进行人工裁决',
                  style: Theme.of(context).textTheme.labelLarge),
            ]),
          ]),
        ),
      ),
    );
  }
}
