import '../models/ai_source.dart';

/// 正文引用与来源卡之间的稳定映射。
///
/// 服务端在不同阶段可能返回 citation_numbers，也可能只有来源顺序。
/// 这里集中处理两种契约，避免页面 rebuild 后引用编号漂移或重复渲染来源卡。
class AiCitationMapping {
  const AiCitationMapping({
    required this.content,
    required this.sources,
    required this.chunkToCitation,
    required this.unresolvedChunkIds,
  });

  final String content;
  final List<AiSource> sources;
  final Map<int, int> chunkToCitation;
  final List<int> unresolvedChunkIds;

  bool get hasUnresolvedChunks => unresolvedChunkIds.isNotEmpty;
}

AiCitationMapping resolveMessageSources({
  required String content,
  required List<AiSource> sources,
}) {
  final normalizedSources = deduplicateAiSources(sources);
  final renderedSources = <AiSource>[];
  final chunkToCitation = <int, int>{};
  var nextCitation = 1;

  for (final source in normalizedSources) {
    final citationNumbers = source.citationNumbers.isNotEmpty
        ? source.citationNumbers
        : <int>[nextCitation++];
    if (source.citationNumbers.isNotEmpty) {
      final maxCitation = citationNumbers.reduce((a, b) => a > b ? a : b);
      if (maxCitation >= nextCitation) nextCitation = maxCitation + 1;
    }
    renderedSources.add(
      source.copyWith(citationNumbers: citationNumbers),
    );

    final chunkIds = source.chunkIds.isNotEmpty
        ? source.chunkIds
        : (source.chunkId > 0 ? <int>[source.chunkId] : const <int>[]);
    for (var index = 0; index < chunkIds.length; index++) {
      final number = citationNumbers[
          index < citationNumbers.length ? index : citationNumbers.length - 1];
      chunkToCitation.putIfAbsent(chunkIds[index], () => number);
    }
  }

  final unresolved = <int>{};
  final rendered = content.replaceAllMapped(
    RegExp(r'\[chunk:([^\]\s]+)\]', caseSensitive: false),
    (match) {
      final chunkId = int.tryParse(match.group(1) ?? '');
      final citation = chunkId == null ? null : chunkToCitation[chunkId];
      if (citation == null) {
        if (chunkId != null && chunkId > 0) unresolved.add(chunkId);
        return '[来源暂不可用]';
      }
      return '[$citation]';
    },
  );

  return AiCitationMapping(
    content: rendered,
    sources: renderedSources,
    chunkToCitation: Map.unmodifiable(chunkToCitation),
    unresolvedChunkIds: List.unmodifiable(unresolved),
  );
}

List<AiSource> deduplicateAiSources(Iterable<AiSource> sources) {
  final byKey = <String, AiSource>{};
  for (final source in sources) {
    final existing = byKey[source.stableKey];
    if (existing == null) {
      byKey[source.stableKey] = source;
      continue;
    }
    final numbers = <int>{
      ...existing.citationNumbers,
      ...source.citationNumbers,
    };
    final chunks = <int>{
      ...existing.chunkIds,
      ...source.chunkIds,
      if (existing.chunkId > 0) existing.chunkId,
      if (source.chunkId > 0) source.chunkId,
    };
    byKey[source.stableKey] = existing.copyWith(
      citationNumbers: numbers.toList(growable: false),
      chunkIds: chunks.toList(growable: false),
    );
  }
  return byKey.values.toList(growable: false);
}

List<int> extractAiChunkIds(String content) {
  final ids = <int>{};
  for (final match in RegExp(r'\[chunk:([^\]\s]+)\]', caseSensitive: false)
      .allMatches(content)) {
    final id = int.tryParse(match.group(1) ?? '');
    if (id != null && id > 0) ids.add(id);
  }
  return ids.toList(growable: false);
}
