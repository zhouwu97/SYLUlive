import 'dart:math';

/// 生成 128 位随机 id，形状与 RFC 4122 v4 一致（32 位十六进制，无连字符）。
///
/// 表情系统里有两处身份必须是「本机唯一」而不是「由外部标识推导」：
/// 匿名使用会话（同一台设备上的不同会话要能分开认领），以及第三方表情包的本地身份
/// （两个都自称 `cat_daily` 的包不能撞成同一个本地 Pack）。用内容无关的随机 id
/// 才能把外部命名空间和本地命名空间彻底隔开。
///
/// 项目未引入 uuid 依赖，这里直接用 [Random.secure] 拼出 v4 形状的 id；
/// 版本位与变体位按 RFC 4122 置好，便于以后与标准 UUID 互认。
String newEmojiLocalId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10x
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
