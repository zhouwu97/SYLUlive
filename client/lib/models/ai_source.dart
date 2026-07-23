enum AiSourceType { policy, schedule }

class AiSource {
  final AiSourceType type;
  final int chunkId;
  final int documentId;
  final String title;
  final String publisher;
  final String status;
  final String? url;

  const AiSource({
    required this.type,
    this.chunkId = 0,
    this.documentId = 0,
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
      chunkId: int.tryParse('${json['chunk_id'] ?? ''}') ?? 0,
      documentId: int.tryParse('${json['document_id'] ?? ''}') ?? 0,
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

class AiSourceContent {
  final int chunkId;
  final int documentId;
  final String title;
  final String content;
  final String sectionTitle;
  final String locator;

  const AiSourceContent({
    required this.chunkId,
    required this.documentId,
    required this.title,
    required this.content,
    this.sectionTitle = '',
    this.locator = '',
  });

  factory AiSourceContent.fromJson(Map<String, dynamic> json) {
    return AiSourceContent(
      chunkId: int.tryParse('${json['chunk_id'] ?? ''}') ?? 0,
      documentId: int.tryParse('${json['document_id'] ?? ''}') ?? 0,
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      sectionTitle: json['section_title']?.toString() ?? '',
      locator: json['locator']?.toString() ?? '',
    );
  }
}
