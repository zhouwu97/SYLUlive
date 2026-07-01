import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'app_navigator.dart';

class AppFeedback {
  const AppFeedback._();

  static String dioErrorMessage(
    DioException e, {
    String serviceName = '服务器',
    String fallback = '操作失败',
  }) {
    final data = e.response?.data;
    if (data is Map) {
      final detail = data['detail'] ?? data['error'] ?? data['message'];
      if (detail != null && detail.toString().trim().isNotEmpty) {
        return detail.toString();
      }
    }

    switch (e.response?.statusCode) {
      case 400:
        return '请求参数有误，请检查填写内容';
      case 401:
        return serviceName == '教务服务' ? '教务账号或密码错误' : '登录已过期或账号密码错误';
      case 403:
        return '没有权限执行该操作';
      case 404:
        return '请求的内容不存在或已被删除';
      case 409:
        return '当前内容状态已变化，请刷新后重试';
      case 422:
        return '填写内容不完整，请检查后重试';
      case 429:
        return '操作过于频繁，请稍后再试';
      case 500:
      case 502:
      case 503:
      case 504:
        return '$serviceName暂时不可用，请稍后再试';
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接$serviceName超时，请检查网络后重试';
      case DioExceptionType.sendTimeout:
        return '请求发送超时，请检查网络后重试';
      case DioExceptionType.receiveTimeout:
        return '$serviceName响应超时，请稍后再试';
      case DioExceptionType.transformTimeout:
        return '$serviceName数据解析超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接$serviceName，请检查网络或稍后重试';
      case DioExceptionType.badCertificate:
        return '$serviceName证书异常，请稍后再试';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return e.message?.trim().isNotEmpty == true ? e.message! : fallback;
    }
  }

  static void showSnackBar(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade600 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static void showGlobalToast(String message, {bool isError = false}) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade600 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static Future<void> showErrorDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade400),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(message, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  static Future<bool> confirmDanger(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '确认删除',
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title),
        content: Text(message, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
