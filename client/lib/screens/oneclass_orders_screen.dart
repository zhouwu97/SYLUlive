import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

class OneClassOrdersScreen extends StatefulWidget {
  const OneClassOrdersScreen({super.key});

  @override
  State<OneClassOrdersScreen> createState() => _OneClassOrdersScreenState();
}

class _OneClassOrdersScreenState extends State<OneClassOrdersScreen> {
  String _status = '';
  String _tier = '';
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadOrders();
  }

  Future<Map<String, dynamic>> _loadOrders() async {
    final auth = context.read<AuthProvider>();
    final res = await auth.dio.get('/oneclass/admin/orders', queryParameters: {
      if (_status.isNotEmpty) 'status': _status,
      if (_tier.isNotEmpty) 'tier': _tier,
      'page': 1,
      'page_size': 50,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> _refresh() async {
    final future = _loadOrders();
    if (mounted) setState(() => _future = future);
    await future;
  }

  String _money(dynamic cents) {
    final value = int.tryParse('${cents ?? 0}') ?? 0;
    return '¥${(value / 100).toStringAsFixed(2)}';
  }

  String _tierLabel(Map<String, dynamic> order) {
    return '${order['tier_label'] ?? order['tier'] ?? '-'}';
  }

  String _userLabel(Map<String, dynamic> order) {
    final user = order['user'];
    if (user is Map) {
      return '${user['nickname'] ?? user['student_id'] ?? order['user_id'] ?? '-'}';
    }
    return '${order['user_id'] ?? '-'}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'cancelled':
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF10131A) : const Color(0xFFF4F6FB),
      appBar: AppBar(
        title: const Text('OneClass 订单'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: '支付状态'),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('全部')),
                      DropdownMenuItem(value: 'pending', child: Text('待支付')),
                      DropdownMenuItem(value: 'completed', child: Text('已完成')),
                      DropdownMenuItem(value: 'cancelled', child: Text('已取消')),
                    ],
                    onChanged: (v) {
                      setState(() => _status = v ?? '');
                      _refresh();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _tier,
                    decoration: const InputDecoration(labelText: '套餐'),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('全部')),
                      DropdownMenuItem(value: 'one_time', child: Text('一次性购买')),
                      DropdownMenuItem(value: 'lifetime_updates', child: Text('长期更新')),
                      DropdownMenuItem(value: 'upgrade_updates', child: Text('补差升级')),
                    ],
                    onChanged: (v) {
                      setState(() => _tier = v ?? '');
                      _refresh();
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<Map<String, dynamic>>(
              future: _future,
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  final error = snap.error;
                  final message = error is DioException
                      ? (error.response?.data is Map
                          ? '${(error.response?.data as Map)['error'] ?? error.message}'
                          : '${error.message}')
                      : '$error';
                  return Center(child: Text('加载失败：$message'));
                }
                final data = snap.data ?? {};
                final orders = (data['orders'] as List?) ?? const [];
                if (orders.isEmpty) {
                  return const Center(child: Text('暂无 OneClass 订单'));
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final order = Map<String, dynamic>.from(orders[i] as Map);
                      final status = '${order['status'] ?? ''}';
                      final hasToken = order['has_license_token'] == true;
                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${order['order_no'] ?? '-'}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(status),
                                    labelStyle: const TextStyle(color: Colors.white),
                                    backgroundColor: _statusColor(status),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('用户：${_userLabel(order)}'),
                              Text('套餐：${_tierLabel(order)} · ${_money(order['amount_cents'])}'),
                              Text('机器码：${order['machine_id'] ?? '-'}'),
                              Text('支付宝交易号：${order['trade_no'] ?? '-'}'),
                              Text('授权：${hasToken ? '已签发' : '未签发'}'),
                              Text('付款时间：${order['paid_at'] ?? '-'}'),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
