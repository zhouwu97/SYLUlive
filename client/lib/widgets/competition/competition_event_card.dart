import 'package:flutter/material.dart';

import '../../models/competition.dart';
import 'competition_admin_event_card.dart';
import 'competition_student_event_card.dart';

class CompetitionEventCard extends StatelessWidget {
  final CompetitionEvent event;
  final bool isAdmin;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onAddPlan;
  final VoidCallback? onEdit;
  final VoidCallback? onPublish;
  final VoidCallback? onArchive;

  const CompetitionEventCard({
    super.key,
    required this.event,
    this.isAdmin = false,
    this.selectionMode = false,
    this.isSelected = false,
    required this.onTap,
    required this.onAddPlan,
    this.onEdit,
    this.onPublish,
    this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    if (isAdmin) {
      return CompetitionAdminEventCard(
        event: event,
        selectionMode: selectionMode,
        isSelected: isSelected,
        onTap: onTap,
        onEdit: onEdit,
        onPublish: onPublish,
        onArchive: onArchive,
      );
    }
    return CompetitionStudentEventCard(
      event: event,
      onTap: onTap,
      onAddPlan: onAddPlan,
      onJoinedTap: onTap,
    );
  }
}
