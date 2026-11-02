import 'package:shenliyuan/widgets/app_card.dart';
import 'package:flutter/material.dart';

import '../widgets/app_page_background.dart';
import '../legal/legal_documents.dart';
import '../widgets/campus/campus_theme.dart';

class LegalDocumentsScreen extends StatelessWidget {
  final String? initialDocumentId;

  const LegalDocumentsScreen({super.key, this.initialDocumentId});

  static Future<void> open(BuildContext context, {String? documentId}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LegalDocumentsScreen(initialDocumentId: documentId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      AppPageBackground(builder: _buildPageWithBackground);

  Widget _buildPageWithBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? CampusTheme.darkBg : CampusTheme.bg;
    final initial = initialDocumentId == null
        ? null
        : LegalDocuments.byId(initialDocumentId!);
    return Scaffold(
      backgroundColor: AppPageBackground.color(context, bg),
      appBar: AppBar(
        backgroundColor: AppPageBackground.color(context, bg),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          initial?.title ?? '协议与隐私政策',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: initial == null
          ? ListView(
              addRepaintBoundaries: false,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                AppCardSurface(
                  decoration: BoxDecoration(
                    color: isDark ? CampusTheme.darkCard : CampusTheme.card,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < LegalDocuments.all.length; i++) ...[
                        if (i > 0) const AppCardDivider(height: 1),
                        ListTile(
                          title: Text(LegalDocuments.all[i].title),
                          subtitle: Text(LegalDocuments.all[i].summary),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => open(context,
                              documentId: LegalDocuments.all[i].id),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            )
          : _DocumentBody(document: initial),
    );
  }
}

class _DocumentBody extends StatelessWidget {
  final LegalDocument document;

  const _DocumentBody({required this.document});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SelectionArea(
      child: ListView(
        addRepaintBoundaries: false,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          AppCardSurface(
            key: const ValueKey('legal-document-reading-surface'),
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.zero,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  document.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  document.summary,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 24),
                Text(
                  document.body.trim(),
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(height: 1.65),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
