import 'package:flutter/material.dart';
import '../../widgets/glass_container.dart';

/// Exposure-specific UI rendered inside [MarketPublishForm] when the post type
/// is 'exposure'.
///
/// This is a StatelessWidget — all controller state is owned by the parent
/// form.  If exposure ever gains unique required fields it can be promoted to
/// StatefulWidget without changing callers.
class ExposurePublishForm extends StatelessWidget {
  const ExposurePublishForm({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      blur: 10,
      opacity: 0.1,
      child: Row(
        children: [
          Icon(Icons.warning, color: Colors.orange[700]),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '曝光骗子需提供充分证据，我们会对内容进行审核',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
