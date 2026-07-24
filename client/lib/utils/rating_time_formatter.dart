import 'package:intl/intl.dart';

String formatRatingTime(DateTime? createdAt, DateTime? updatedAt) {
  if (createdAt == null) {
    return '';
  }

  final now = DateTime.now();
  final difference = now.difference(createdAt);

  String timeString;
  if (difference.inSeconds < 60) {
    timeString = '刚刚';
  } else if (difference.inHours < 1) {
    timeString = '${difference.inMinutes}分钟前';
  } else if (createdAt.year == now.year &&
      createdAt.month == now.month &&
      createdAt.day == now.day) {
    timeString = DateFormat('HH:mm').format(createdAt);
  } else if (createdAt.year == now.year) {
    timeString = DateFormat('M月d日').format(createdAt);
  } else {
    timeString = DateFormat('yyyy年M月d日').format(createdAt);
  }

  final edited = updatedAt != null &&
      updatedAt.difference(createdAt).inSeconds >= 60;

  if (edited) {
    return '$timeString · 已编辑';
  }
  return timeString;
}
