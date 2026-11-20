import 'team_share_link.dart';

/// 商家分享链接：指向 Web 应用的商家详情页 /web/canteen/:id（Web 的 base 是 /web/），
/// 任何浏览器都能直接打开，不依赖网关为 /canteen/ 单独配置落地页。
Uri canteenShareUri(int canteenId) => Uri(
      scheme: 'https',
      host: TeamShareLink.domain,
      pathSegments: ['web', 'canteen', '$canteenId'],
    );

/// 分享文案只用公开信息（店名、位置、公开评分），不带任何个人数据。
String canteenShareText({
  required int canteenId,
  required String name,
  String location = '',
  double averageStar = 0,
  int ratingCount = 0,
  String dishName = '',
}) {
  final title = dishName.isEmpty ? '「$name」' : '「$name」的「$dishName」';
  final parts = [
    title,
    if (location.isNotEmpty) location,
    if (ratingCount > 0)
      '${averageStar.toStringAsFixed(1)} 分（$ratingCount 位同学评价）',
  ];
  return '${parts.join(' · ')}\n来沈理校园看同学的真实评价：${canteenShareUri(canteenId)}';
}
