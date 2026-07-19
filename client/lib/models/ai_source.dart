enum AiSourceType { policy, schedule }

class AiSource {
  final AiSourceType type;
  final String title;
  final String publisher;
  final String status;
  final String? url;

  const AiSource({
    required this.type,
    required this.title,
    this.publisher = '',
    this.status = '',
    this.url,
  });

  factory AiSource.fromJson(Map<String, dynamic> json) {
    return AiSource(
      type: json['type'] == 'schedule'
          ? AiSourceType.schedule
          : AiSourceType.policy,
      title: json['title']?.toString() ?? '',
      publisher: json['publisher']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      url: json['url']?.toString(),
    );
  }

  String get typeLabel => type == AiSourceType.schedule ? '课表缓存' : '校园政策';

  String get reliabilityNote => type == AiSourceType.schedule
      ? '来自本机已同步课表缓存，并非实时教务数据。'
      : '请以来源文件当前有效版本为准。';
}
