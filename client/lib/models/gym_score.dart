/// 体测成绩单项模型
class GymScoreItem {
  final String subName; // 项目名称：肺活量、50米等
  final String result; // 成绩数值
  final String scoreStatus; // 状态：1=优秀 2=及格 3=不及格 等

  const GymScoreItem({
    required this.subName,
    required this.result,
    required this.scoreStatus,
  });

  factory GymScoreItem.fromJson(Map<String, dynamic> json) {
    return GymScoreItem(
      subName: json['sub_name'] ?? '',
      result: json['result'] ?? '',
      scoreStatus: json['score_status']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'sub_name': subName,
        'result': result,
        'score_status': scoreStatus,
      };

  /// 状态文字
  String get statusLabel {
    switch (scoreStatus) {
      case '1':
        return '优秀';
      case '2':
        return '及格';
      case '3':
        return '不及格';
      default:
        return '未知';
    }
  }

  /// 状态颜色
  int get statusColorValue {
    switch (scoreStatus) {
      case '1':
        return 0xFF16A34A; // 绿
      case '2':
        return 0xFF6366F1; // 蓝紫
      case '3':
        return 0xFFEF4444; // 红
      default:
        return 0xFF9CA3AF; // 灰
    }
  }
}

/// 体测接口响应
class GymScoreResponse {
  final int code;
  final List<GymScoreItem> data;

  const GymScoreResponse({required this.code, required this.data});

  factory GymScoreResponse.fromJson(Map<String, dynamic> json) {
    final list = (json['data'] as List<dynamic>?) ?? [];
    return GymScoreResponse(
      code: json['code'] ?? 0,
      data: list
          .map((e) => GymScoreItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
