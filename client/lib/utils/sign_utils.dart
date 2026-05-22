import 'dart:convert';
import 'package:crypto/crypto.dart';

/// API 签名工具 — 字典序 + 固定盐值 + SHA-1
///
/// 完全复刻 JS 前端 sign 生成逻辑：
/// 1. 剔除 null / 空字符串(toString) / sign 自身
/// 2. 按键名 ASCII 升序排列
/// 3. 用 & 拼接成 key=value 格式
/// 4. 末尾追加 &key=<salt>
/// 5. SHA-1 哈希 → 大写
class SignUtils {
  static const String _salt = '8d6c5b73a50d4707bd71c93882ddbc8b';

  static String generateSign(Map<String, dynamic> params) {
    final filtered = <String, dynamic>{};

    // 1. 过滤：严格剔除 null、空字符串 和 sign 本身
    params.forEach((key, value) {
      if (key != 'sign' && value != null && value.toString().isNotEmpty) {
        filtered[key] = value;
      }
    });

    // 2. 排序：按键名字典序 (A-Z)
    final sortedKeys = filtered.keys.toList()..sort();

    // 3. 拼接：key=value&key=value
    final pairs = <String>[];
    for (final key in sortedKeys) {
      pairs.add('$key=${filtered[key]}');
    }
    String signString = pairs.join('&');

    // 4. 加盐
    if (signString.isNotEmpty) {
      signString += '&key=$_salt';
    } else {
      signString = 'key=$_salt';
    }

    // 5. SHA-1 → 大写
    final bytes = utf8.encode(signString);
    final digest = sha1.convert(bytes);
    return digest.toString().toUpperCase();
  }
}
