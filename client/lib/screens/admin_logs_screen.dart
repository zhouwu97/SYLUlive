import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AdminLogsScreen extends StatefulWidget {
  const AdminLogsScreen({super.key});

  @override
  State<AdminLogsScreen> createState() => _AdminLogsScreenState();
}

class _AdminLogsScreenState extends State<AdminLogsScreen> {
  List<dynamic> _logs = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final response = await dio.get('/teachers/logs');
      if (!mounted) return;
      setState(() {
        _logs = (response.data as List?) ?? [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '加载日志失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('操作日志')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _buildLogsContent(isDark),
    );
  }

  Widget _buildLogsContent(bool isDark) {
    if (_logs.isEmpty) {
      return Center(
        child: Text(
          '暂无操作日志',
          style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(12),
        itemCount: _logs.length,
        itemBuilder: (_, i) {
          final log = _logs[i];
          return Card(
            color: isDark ? Colors.grey[850] : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ListTile(
              title: Text(
                '${log['admin_name'] ?? '?'}: ${log['action'] ?? ''}',
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                log['target'] ?? '',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              trailing: Text(
                log['created_at']?.toString().substring(0, 16) ?? '',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          );
        },
      ),
    );
  }
}
