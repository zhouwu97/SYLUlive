import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_source.dart';
import 'package:shenliyuan/utils/ai_citation_mapper.dart';

void main() {
  test('按来源顺序稳定替换 chunk 引用并去重', () {
    const source = AiSource(
      type: AiSourceType.policy,
      chunkId: 18,
      title: '成绩管理办法',
    );
    final result = resolveMessageSources(
      content: '先看 [chunk:18]，再看 [chunk:18]。',
      sources: [source, source],
    );

    expect(result.content, '先看 [1]，再看 [1]。');
    expect(result.sources, hasLength(1));
    expect(result.sources.single.citationLabel, '[1]');
    expect(result.chunkToCitation[18], 1);
    expect(result.unresolvedChunkIds, isEmpty);
  });

  test('来源未恢复时不暴露内部 chunk id', () {
    final result = resolveMessageSources(
      content: '请参考 [chunk:99]。',
      sources: const [],
    );

    expect(result.content, '请参考 [来源暂不可用]。');
    expect(result.unresolvedChunkIds, [99]);
  });

  test('保留服务端显式引用编号并支持多 chunk 来源', () {
    const source = AiSource(
      type: AiSourceType.policy,
      chunkIds: [18, 19],
      title: '学生管理办法',
      citationNumbers: [3, 4],
    );
    final result = resolveMessageSources(
      content: '[chunk:18] [chunk:19]',
      sources: const [source],
    );

    expect(result.content, '[3] [4]');
    expect(result.chunkToCitation, {18: 3, 19: 4});
  });

  test('旧回答中的笼统来源标记会关联已恢复的来源卡片', () {
    const source = AiSource(
      type: AiSourceType.policy,
      chunkId: 18,
      title: '沈阳理工大学学士学位授予条件',
      citationNumbers: [1],
    );

    final result = resolveMessageSources(
      content: '学位课程平均绩点达到 2.0。[来源]',
      sources: const [source],
    );

    expect(result.content, '学位课程平均绩点达到 2.0。[1]');
    expect(hasAiCitationMarkers('请看[来源]'), isTrue);
  });
}
