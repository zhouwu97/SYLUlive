enum AiSourceType { policy, schedule }

class AiSource {
  final AiSourceType type;
  final int chunkId;
  final int documentId;
  final String title;
  final String publisher;
  final String status;
  final String? url;
  final List<int> citationNumbers;
  final List<String> locators;

  const AiSource({
    required this.type,
    this.chunkId = 0,
    this.documentId = 0,
    required this.title,
    this.publisher = '',
    this.status = '',
    this.url,
    this.citationNumbers = const [],
    this.locators = const [],
  });

  factory AiSource.fromJson(Map<String, dynamic> json) {
    return AiSource(
      type: json['type'] == 'schedule'
          ? AiSourceType.schedule
          : AiSourceType.policy,
      chunkId: int.tryParse(
              '${json['primary_chunk_id'] ?? json['chunk_id'] ?? ''}') ??
          0,
      documentId: int.tryParse('${json['document_id'] ?? ''}') ?? 0,
      title: json['title']?.toString() ?? '',
      publisher:
          json['publisher']?.toString() ?? json['department']?.toString() ?? '',
      status:
          json['status']?.toString() ?? json['confidence']?.toString() ?? '',
      url: json['url']?.toString(),
      citationNumbers: _intList(json['citation_numbers']),
      locators: _stringList(json['locators']),
    );
  }

  String get typeLabel => type == AiSourceType.schedule ? '课表缓存' : '校园政策';

  String get reliabilityNote => type == AiSourceType.schedule
      ? '来自本机已同步课表缓存，并非实时教务数据。'
      : '请以来源文件当前有效版本为准。';

  String get citationLabel =>
      citationNumbers.map((number) => '[$number]').join();
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

List<int> _intList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => int.tryParse(item.toString()) ?? 0)
      .where((item) => item > 0)
      .toList(growable: false);
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
