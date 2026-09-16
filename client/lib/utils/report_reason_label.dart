/// 举报/治理原因码 → 中文标签。
///
/// 管理端举报处理页与整改复审待办必须用同一张映射表：两边都展示"这条内容当初
/// 为什么被处理"，各自维护一份必然漂移，出现同一个码在两个页面显示不同文案。
///
/// - 已知 `code` 直接返回对应中文；
/// - `code` 未知时先尝试用 `fallbackText`（举报人自由文本 / 旧数据）匹配，
///   匹配不到就原样返回 `fallbackText`；
/// - 都为空时返回“未知”。
String reportReasonLabel({String? code, String? fallbackText}) {
  const reasonMap = <String, String>{
    'spam': '垃圾广告',
    'porn': '色情低俗',
    'violence': '暴力血腥',
    'fake': '虚假信息',
    'privacy': '侵犯隐私',
    'harassment': '人身攻击',
    'fabricated': '捏造或失实',
    'false': '虚假信息',
    'unrelated': '与菜品无关',
    'unrelated_photo': '图片与菜品无关',
    'unrelated_content': '内容与目标无关',
    'fake_dish': '虚假菜品',
    'stolen_photo': '盗用图片',
    'malicious': '恶意内容',
    'malicious_repeat': '重复恶意内容',
    'abuse': '辱骂或恶意内容',
    'other': '其他',
  };
  final normalizedCode = code?.trim() ?? '';
  if (normalizedCode.isNotEmpty && reasonMap[normalizedCode] != null) {
    return reasonMap[normalizedCode]!;
  }
  final normalizedFallback = fallbackText?.trim() ?? '';
  if (normalizedFallback.isEmpty) return '未知';
  return reasonMap[normalizedFallback] ?? normalizedFallback;
}
