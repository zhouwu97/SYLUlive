import 'package:dio/dio.dart';

import '../models/campus_article.dart';

/// 校园资讯文章网络服务。
///
/// 使用项目共享的 Dio 实例和 [ApiConstants.baseUrl]，不引入硬编码地址。
/// 调用方应捕获 [DioException] 并使用 [AppFeedback.dioErrorMessage] 显示
/// 用户可理解的错误信息；数据格式异常时抛出 [CampusArticleServiceException]。
class CampusArticleService {
  final Dio _dio;

  CampusArticleService(this._dio);

  /// 获取最新一篇文章。
  ///
  /// 后端返回 `{item: DetailItem | null}`。当数据库无文章时返回 null。
  Future<CampusArticleSummary?> getLatestArticle() async {
    final response = await _dio.get('/campus/articles/latest');
    if (response.statusCode != 200 || response.data is! Map) {
      throw const CampusArticleServiceException('数据格式错误');
    }
    final item = response.data['item'];
    if (item == null || item is! Map) return null;
    // latest 接口返回完整 DetailItem，但首页只需要摘要字段
    return CampusArticleSummary.fromJson(
      Map<String, dynamic>.from(item),
    );
  }

  /// 分页获取文章列表。
  ///
  /// [categorySlug] 传 `jwtz` 或 `jwgg` 进行分类筛选，传 null 获取全部。
  Future<CampusArticlePage> getArticles({
    int page = 1,
    int pageSize = 20,
    String? categorySlug,
  }) async {
    final params = <String, dynamic>{
      'page': page,
      'page_size': pageSize,
    };
    if (categorySlug != null && categorySlug.isNotEmpty) {
      params['category'] = categorySlug;
    }

    final response = await _dio.get(
      '/campus/articles',
      queryParameters: params,
    );
    if (response.statusCode != 200 || response.data is! Map) {
      throw const CampusArticleServiceException('数据格式错误');
    }
    return CampusArticlePage.fromJson(
      Map<String, dynamic>.from(response.data),
    );
  }

  /// 获取文章完整详情（含正文和附件）。
  ///
  /// 后端返回 `{item: DetailItem}`。文章不存在时后端返回 404，
  /// Dio 会抛出 DioException（badResponse），由调用方处理。
  Future<CampusArticleDetail> getArticleDetail(int id) async {
    final response = await _dio.get('/campus/articles/$id');
    if (response.statusCode != 200 || response.data is! Map) {
      throw const CampusArticleServiceException('数据格式错误');
    }
    final item = response.data['item'];
    if (item == null || item is! Map) {
      throw const CampusArticleServiceException('文章数据为空');
    }
    return CampusArticleDetail.fromJson(Map<String, dynamic>.from(item));
  }
}

/// 服务层数据格式异常，用于区分网络错误和解析错误。
class CampusArticleServiceException implements Exception {
  final String message;
  const CampusArticleServiceException(this.message);

  @override
  String toString() => message;
}
