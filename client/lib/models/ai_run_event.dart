import 'ai_quota.dart';
import 'ai_source.dart';

enum AiRunEventType { started, status, delta, sources, completed, failed }

class AiRunEvent {
  final AiRunEventType type;
  final String text;
  final String status;
  final List<AiSource> sources;
  final AiQuota? quota;

  const AiRunEvent({
    required this.type,
    this.text = '',
    this.status = '',
    this.sources = const [],
    this.quota,
  });
}
