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
          IconButton(
              tooltip: '刷新指标',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh))
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
                          Text('最近 ${metrics['days'] ?? 7} 天',
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _metric('调用', '${metrics['requests'] ?? 0}'),
                              _metric('成功率',
                                  '${((metrics['success_rate'] as num? ?? 0) * 100).toStringAsFixed(1)}%'),
                              _metric('Tokens',
                                  '${metrics['input_output_tokens'] ?? 0}'),
                              _metric('预估成本', _formatMetricCost(metrics)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            metrics['cost_currency'] == 'USD'
                                ? '金额单位：美元（USD）。按 GPT 优享价表及已记录用量估算，不代表上游实际扣费。'
                                : '金额单位：人民币元。按服务端配置单价和已记录用量估算，不代表上游实际扣费。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (metrics['cost_currency'] == 'USD')
                            Text(
                              '已定价 ${metrics['priced_requests'] ?? 0} 条 · 未定价 ${metrics['unpriced_requests'] ?? 0} 条；未定价记录不计入金额。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          const SizedBox(height: 16),
                          _section('延迟', metrics['latency_ms']),
                          _section('Provider', metrics['by_provider']),
                          _section('模型', metrics['by_model']),
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
                  // 金额放入可换行的正文区，避免大字号下与 Provider 名称挤占宽度。
                  isThreeLine: true,
                  subtitle: Text(
                      '调用 ${item['requests'] ?? item['count'] ?? 0} · Tokens ${item['tokens'] ?? 0}\n预估成本 ${_formatMetricCost(item)}${(item['unpriced_requests'] as num? ?? 0) > 0 ? ' · ${item['unpriced_requests']} 条未定价' : ''}'),
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

String _formatMetricCost(Map<dynamic, dynamic> metrics) {
  if (metrics['cost_currency'] == 'USD') {
    if ((metrics['unpriced_requests'] as num? ?? 0) > 0 &&
        (metrics['priced_requests'] as num? ?? 0) == 0) {
      return '未定价';
    }
    final value = metrics['cost_nano_usd'];
    final nanoUSD = value is num ? value : num.tryParse('$value');
    if (nanoUSD == null || !nanoUSD.isFinite || nanoUSD < 0) return '—';
    // 低至单个缓存 token 的费用仍需可见；美元与历史人民币估算绝不混算。
    return '\$${(nanoUSD / 1000000000).toStringAsFixed(nanoUSD > 0 && nanoUSD < 1000 ? 9 : 6)}';
  }
  final value = metrics['cost_micro_yuan'];
  final microYuan = value is num ? value : num.tryParse('$value');
  if (microYuan == null || !microYuan.isFinite || microYuan < 0) return '—';
  // 微元是存储精度，不是面向管理员的货币单位；小额保留到微元，避免被显示为零。
  final yuan = microYuan / 1000000;
  return '¥${yuan.toStringAsFixed(microYuan > 0 && microYuan < 100 ? 6 : 4)}';
}
