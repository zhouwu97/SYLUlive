import 'user.dart';

class LotteryEvent {
  final int id;
  final String title;
  final String description;
  final String prizeName;
  final DateTime drawTime;
  final int status; // 0: Upcoming/Ongoing, 1: Drawn
  final int? winnerId;
  final User? winner;

  LotteryEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.prizeName,
    required this.drawTime,
    required this.status,
    this.winnerId,
    this.winner,
  });

  factory LotteryEvent.fromJson(Map<String, dynamic> json) {
    return LotteryEvent(
      id: json['id'],
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      prizeName: json['prize_name'] ?? '',
      drawTime: DateTime.parse(json['draw_time']),
      status: json['status'] ?? 0,
      winnerId: json['winner_id'],
      winner: json['winner'] != null ? User.fromJson(json['winner']) : null,
    );
  }
}
