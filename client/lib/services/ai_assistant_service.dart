import 'package:dio/dio.dart';

import '../models/ai_capabilities.dart';

class AiAssistantService {
  final Dio _dio;

  AiAssistantService(this._dio);

  Future<AiCapabilities> getCapabilities() async {
    final response = await _dio.get('/ai/capabilities');
    if (response.statusCode != 200 || response.data is! Map) {
      throw const AiAssistantServiceException('AI 能力信息格式错误');
    }
    return AiCapabilities.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }
}

class AiAssistantServiceException implements Exception {
  final String message;
  const AiAssistantServiceException(this.message);

  @override
  String toString() => message;
}
