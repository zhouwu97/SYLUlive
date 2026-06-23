import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/api_constants.dart';

/// 动态脚本加载服务
/// 负责在 App 启动时或进入上课页面前，向 Go 后端请求最新的 JS 拦截脚本并缓存在内存中。
class ScriptService {
  // 单例模式
  static final ScriptService _instance = ScriptService._internal();
  factory ScriptService() => _instance;
  ScriptService._internal();

  final Dio _dio = Dio();
  String? _cachedScript;

  /// 获取缓存的注入脚本。如果内存中没有，则向后端请求。
  Future<String?> getInjectScript() async {
    // 强制每次获取最新脚本，避免热重载时缓存导致不生效
    try {
      final response =
          await _dio.get('${ApiConstants.baseUrl}/v1/config/inject-script');

      if (response.statusCode == 200 && response.data['success'] == true) {
        _cachedScript = response.data['script'] as String?;
        debugPrint('成功从服务器获取并缓存 JS 探针脚本');
        return _cachedScript;
      } else {
        debugPrint('获取 JS 探针脚本失败: ${response.data}');
        return null;
      }
    } catch (e) {
      debugPrint('请求 JS 探针脚本发生异常: $e');
      return null;
    }
  }

  /// 预加载脚本（可在 App 启动时调用）
  Future<void> preload() async {
    await getInjectScript();
  }
}
