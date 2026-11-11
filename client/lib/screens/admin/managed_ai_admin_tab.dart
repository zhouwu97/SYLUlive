import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../widgets/app_card.dart';

class ManagedAIAdminTab extends StatefulWidget {
  const ManagedAIAdminTab({super.key, required this.dio});
  final Dio dio;

  @override
  State<ManagedAIAdminTab> createState() => _ManagedAIAdminTabState();
}

class _ManagedAIAdminTabState extends State<ManagedAIAdminTab> {
  late Future<Response<dynamic>> _request;

  @override
  void initState() {
    super.initState();
    _request = _load();
  }

  @override
  void didUpdateWidget(covariant ManagedAIAdminTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.dio, widget.dio)) _request = _load();
  }

  Future<Response<dynamic>> _load() {
    final request =
        widget.dio.get('/super/users', queryParameters: {'kind': 'ai'});
    request.ignore();
    return request;
  }

  void _refresh() => setState(() {
        _request = _load();
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<Response<dynamic>>(
        future: _request,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final denied = error is DioException &&
                (error.response?.statusCode == 401 ||
                    error.response?.statusCode == 403);
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(denied ? '需要超级管理员权限，请重新登录后查看' : '暂时无法读取所属 AI'),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ]),
            );
          }
          final items = (snapshot.data?.data as List? ?? const [])
              .whereType<Map>()
              .toList();
          return Column(children: [
            Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'))),
            Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('尚无用户创建的 AI'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final ai = items[index];
                          return AppCard(
                              child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${ai['name']}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const SizedBox(height: 6),
                                  Text(
                                      '归属于 ${ai['owner_name']} · 用户 #${ai['owner_id']}'),
                                  Text(ai['enabled'] == true
                                      ? 'AI 已启用'
                                      : 'AI 已暂停'),
                                  const SizedBox(height: 6),
                                  SelectableText('${ai['id']}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ]),
                          ));
                        },
                      )),
          ]);
        },
      );
}
