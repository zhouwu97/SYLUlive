import 'package:flutter/material.dart';

class AiAssistantIntroCard extends StatelessWidget {
  final String title;
  final String subtitle;

  const AiAssistantIntroCard({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF20272B),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF7B8388),
            height: 1.45,
          ),
        ),
      ],
    );
  }
}
