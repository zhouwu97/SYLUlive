import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? CampusTheme.darkBg : CampusTheme.bg;
    final initial = initialDocumentId == null
        ? null
        : LegalDocuments.byId(initialDocumentId!);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
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
          ? ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: LegalDocuments.all.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final document = LegalDocuments.all[index];
                return ListTile(
                  title: Text(document.title),
                  subtitle: Text(document.summary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(context, documentId: document.id),
                );
              },
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
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
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
            style:
                Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.65),
          ),
        ],
      ),
    );
  }
}
