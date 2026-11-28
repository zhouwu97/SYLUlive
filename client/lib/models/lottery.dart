import 'user.dart';

class LotteryEvent {
  static const int statusOngoing = 0;
  static const int statusDrawn = 1;
  static const int statusNoWinner = 2;
  static const int statusCancelled = 3;

  final int id;
  final String title;
  final String description;
  final String prizeName;

  /// 奖品图的 /uploads/ 路径；空串表示未上传。
  final String prizeImage;
  final DateTime drawTime;
  final int status; // 0: 进行中, 1: 已开奖, 2: 已流拍, 3: 已取消
  final int? winnerId;
  final DateTime? drawnAt;
  final String drawMode;
  final User? winner;
  final int participantCount;
  final bool joined;

  LotteryEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.prizeName,
    this.prizeImage = '',
    required this.drawTime,
    required this.status,
    this.winnerId,
    this.drawnAt,
    this.drawMode = '',
    this.winner,
    this.participantCount = 0,
    this.joined = false,
  });

  bool get isOngoing => status == statusOngoing;
  bool get isDrawn => status == statusDrawn;
  bool get isNoWinner => status == statusNoWinner;
  bool get isCancelled => status == statusCancelled;

  String get statusLabel {
    switch (status) {
      case statusOngoing:
        return '进行中';
      case statusDrawn:
        return '已开奖';
      case statusNoWinner:
        return '已流拍';
      case statusCancelled:
        return '已取消';
      default:
        return '已结束';
    }
  }

  factory LotteryEvent.fromJson(Map<String, dynamic> json) {
    final drawnAtRaw = json['drawn_at']?.toString();
    return LotteryEvent(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      prizeName: json['prize_name']?.toString() ?? '',
      prizeImage: json['prize_image']?.toString() ?? '',
      drawTime:
          DateTime.tryParse(json['draw_time']?.toString() ?? '') ?? DateTime.now(),
      status: (json['status'] as num?)?.toInt() ?? statusOngoing,
      winnerId: (json['winner_id'] as num?)?.toInt(),
      drawnAt: (drawnAtRaw != null && drawnAtRaw.isNotEmpty)
          ? DateTime.tryParse(drawnAtRaw)
          : null,
      drawMode: json['draw_mode']?.toString() ?? '',
      winner: json['winner'] is Map
          ? User.fromJson(Map<String, dynamic>.from(json['winner'] as Map))
          : null,
      participantCount: (json['participant_count'] as num?)?.toInt() ?? 0,
      joined: json['joined'] == true,
    );
  }
}
