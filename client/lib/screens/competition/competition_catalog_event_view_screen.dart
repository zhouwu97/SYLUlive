import 'package:flutter/material.dart';

import '../../models/competition.dart';
import '../../widgets/competition/competition_ui_tokens.dart';

class CompetitionCatalogEventViewScreen extends StatelessWidget {
  const CompetitionCatalogEventViewScreen({super.key, required this.event});

  final CompetitionEvent event;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        title: const Text('查看目录赛事'),
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            event.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          _section(
              '目录治理',
              [
                _row('competition_id', event.competitionId),
                _row('dataset_version', event.datasetVersion),
                _row('catalog_package_id', '${event.catalogPackageId ?? '-'}'),
                _row('record_hash', event.recordHash),
                _row('parent_competition_id', event.parentCompetitionId),
              ],
              isDark),
          _section(
              '权限门',
              [
                _row('搜索展示', event.searchDisplayAllowed ? '允许' : '禁止'),
                _row('候选池', event.candidatePoolAllowed ? '允许' : '禁止'),
                _row('个性化排序', event.personalizedRankingAllowed ? '允许' : '禁止'),
                _row('强推荐资格', event.strongRecommendationEligible ? '允许' : '禁止'),
                _row('推荐权限', event.recommendationPermissionLevel),
                _row('AI 模式', event.aiMode),
              ],
              isDark),
          _section(
              '赛事认定',
              [
                _row('竞赛级别', event.competitionLevel),
                _row('校内认定',
                    '${event.schoolRecognitionStatus} ${event.schoolRecognitionGrade}'),
                _row('价值评级', event.competitionRating),
                _row('证据等级', event.evidenceSubgrade),
              ],
              isDark),
          _section(
              '内容',
              [
                _row('分类', event.primaryCategory?.name ?? '未分类'),
                _row('主办方', event.organizer),
                _row('摘要', event.summary),
                _row('时间', event.displayTimeText),
                _row('来源', event.sourceNote),
              ],
              isDark),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> rows, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: CompetitionUiTokens.cardBg(isDark),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: CompetitionUiTokens.borderColor(isDark)),
            ),
            child: Column(children: rows),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    final display = value.trim().isEmpty ? '未提供' : value.trim();
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(display),
    );
  }
}
