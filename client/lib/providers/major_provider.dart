import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

class MajorItem {
  final int id;
  final String name;
  final String level;
  final int ratingCount;
  final double averageStar;

  MajorItem({required this.id, required this.name, required this.level, this.ratingCount = 0, this.averageStar = 0});

  factory MajorItem.fromJson(Map<String, dynamic> j) => MajorItem(
    id: j['id'] ?? 0, name: j['name'] ?? '', level: j['level'] ?? '',
    ratingCount: j['rating_count'] ?? 0, averageStar: (j['average_star'] ?? 0).toDouble(),
  );
}

class MajorRating {
  final int id, majorId, userId, star;
  final String comment, userName;
  MajorRating({required this.id, required this.majorId, required this.userId, required this.star, required this.comment, this.userName = ''});
  factory MajorRating.fromJson(Map<String, dynamic> j) => MajorRating(
    id: j['id'] ?? 0, majorId: j['major_id'] ?? 0, userId: j['user_id'] ?? 0,
    star: j['star'] ?? 0, comment: j['comment'] ?? '', userName: j['user_name'] ?? '',
  );
}

class MajorProvider extends ChangeNotifier {
  final Dio _dio;
  List<MajorItem> _majors = [];
  MajorItem? _selected;
  List<MajorRating> _ratings = [];
  int _ratingCount = 0;
  double _averageStar = 0;
  bool _isLoading = false;

  List<MajorItem> get majors => _majors;
  MajorItem? get selected => _selected;
  List<MajorRating> get ratings => _ratings;
  int get ratingCount => _ratingCount;
  double get averageStar => _averageStar;
  bool get isLoading => _isLoading;

  MajorProvider(this._dio);

  Future<void> loadMajors() async {
    _isLoading = true; notifyListeners();
    try { final r = await _dio.get('/majors'); _majors = (r.data as List).map((j) => MajorItem.fromJson(j)).toList(); } catch (_) {}
    _isLoading = false; notifyListeners();
  }

  Future<void> loadDetail(int id) async {
    _isLoading = true; notifyListeners();
    try {
      final r = await _dio.get('/majors/$id');
      _selected = MajorItem.fromJson(r.data['major']);
      _ratings = (r.data['ratings'] as List).map((j) => MajorRating.fromJson(j)).toList();
      _ratingCount = r.data['rating_count'] ?? 0;
      _averageStar = (r.data['average_star'] ?? 0).toDouble();
    } catch (_) {}
    _isLoading = false; notifyListeners();
  }

  Future<bool> addMajor(String name, String level) async {
    try { await _dio.post('/majors', data: {'name': name, 'level': level}); await loadMajors(); return true; } catch (_) { return false; }
  }

  Future<bool> rate(int id, int star, String comment) async {
    try { await _dio.post('/majors/$id/rate', data: {'star': star, 'comment': comment}); await loadDetail(id); return true; } catch (_) { return false; }
  }
}
