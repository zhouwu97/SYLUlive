import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

class AdminAIMetricsScreen extends StatefulWidget {
  const AdminAIMetricsScreen({super.key});

  @override
  State<AdminAIMetricsScreen> createState() => _AdminAIMetricsScreenState();
}

class _AdminAIMetricsScreenState extends State<AdminAIMetricsScreen> {
  Map<String, dynamic>? _metrics;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await context.read<AuthProvider>().dio.get(
        '/admin/ai/metrics',
        queryParameters: const <String, dynamic>{'days': 7},
      );
      final data = response.data;
      if (data is! Map) {
        throw const FormatException('指标响应格式错误');
      }
      if (mounted) setState(() => _metrics = Map<String, dynamic>.from(data));
    } on DioException catch (error) {
      if (mounted) {
        setState(
            () => _error = '读取 AI 指标失败（${error.response?.statusCode ?? '网络'}）');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '读取 AI 指标失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 运营指标'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh))
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : metrics == null
                  ? const Center(child: Text('暂无指标'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _metric('调用', '${metrics['requests'] ?? 0}'),
                              _metric('成功率',
                                  '${((metrics['success_rate'] as num? ?? 0) * 100).toStringAsFixed(1)}%'),
                              _metric('Tokens',
                                  '${metrics['input_output_tokens'] ?? 0}'),
                              _metric('成本',
                                  '${metrics['cost_micro_yuan'] ?? 0} μ¥'),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _section('延迟', metrics['latency_ms']),
                          _section('Provider', metrics['by_provider']),
                          _section('用途', metrics['by_purpose']),
                          _section('错误分类', metrics['errors']),
                          _section('Agent 运行', <String, dynamic>{
                            'MCP 工具调用': metrics['mcp_tool_calls'],
                            '设备任务': metrics['device_jobs'],
                          }),
                          const SizedBox(height: 8),
                          const Text(
                            '仅展示聚合计量，不包含问题正文、Prompt、用户标识哈希或密钥。',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
    );
  }

  Widget _metric(String label, String value) => SizedBox(
        width: 150,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 4),
                Text(value,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      );

  Widget _section(String title, dynamic value) {
    if (value is List && value.isNotEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ExpansionTile(
          title: Text(title),
          children: [
            for (final item in value)
              if (item is Map)
                ListTile(
                  dense: true,
                  title: Text('${item['provider'] ?? item['name'] ?? '项目'}'),
                  subtitle: Text(
                      '调用 ${item['requests'] ?? item['count'] ?? 0} · Tokens ${item['tokens'] ?? 0}'),
                  trailing: Text('${item['cost_micro_yuan'] ?? ''}'),
                ),
          ],
        ),
      );
    }
    if (value is! Map || value.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        title: Text(title),
        children: [
          for (final entry in value.entries)
            ListTile(
                dense: true,
                title: Text('${entry.key}'),
                trailing: Text('${entry.value}')),
        ],
      ),
    );
  }
}
