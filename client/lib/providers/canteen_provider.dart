import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/canteen.dart';
import '../config/api_constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CanteenProvider with ChangeNotifier {
  List<Canteen> _canteens = [];
  bool _isLoading = false;

  List<Canteen> get canteens => _canteens;
  bool get isLoading => _isLoading;

  Future<void> loadCanteens() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final response = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/canteens'),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        _canteens = data.map((json) => Canteen.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('Error loading canteens: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> addCanteen(String name, String image) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final response = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/canteens'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'name': name,
          'image': image,
        }),
      );

      return response.statusCode == 201;
    } catch (e) {
      debugPrint('Error adding canteen: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> loadCanteenDetail(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final response = await http.get(
        Uri.parse('${ApiConstants.baseUrl}/canteens/$id'),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error loading canteen detail: $e');
    }
    return {};
  }

  Future<bool> rateCanteen(int id, int star, String comment, List<String> images) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final imagesJson = json.encode(images);
      final response = await http.post(
        Uri.parse('${ApiConstants.baseUrl}/canteens/$id/rate'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: json.encode({
          'star': star,
          'comment': comment,
          'images': imagesJson,
        }),
      );

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('Error rating canteen: $e');
      return false;
    }
  }
}
