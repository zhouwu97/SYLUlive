import 'dart:math';

/// 为一次用户确认动作生成短期幂等键。
///
/// 业务层应在一次动作的重试生命周期内复用返回值；不要为每次网络重试
/// 重新生成键，否则服务端无法判断“响应丢失后的同一次提交”。
String newIdempotencyKey([String prefix = 'action']) {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final suffix = bytes.map(hex).join();
  return '${prefix.trim().isEmpty ? 'action' : prefix.trim()}-$suffix';
}
