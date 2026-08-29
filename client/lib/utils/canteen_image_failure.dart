import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 图片加载失败分类：404/410 表示资源已不存在（如脏记录指向被清理的文件），
/// 可以安全移除对应内容；其余（5xx、网络抖动等）视为瞬时故障，
/// 应保留内容位置等待重试，避免把临时故障渲染成永久缺失。
bool isGoneImageFailure(Object error) {
  return error is HttpExceptionWithStatus &&
      (error.statusCode == 404 || error.statusCode == 410);
}
