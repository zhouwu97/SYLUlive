import 'package:flutter/material.dart';

/// Fixed bottom bar with a full-width publish / save button.
class PublishBottomBar extends StatelessWidget {
  final bool isLoading;
  final VoidCallback? onPressed;
  final String label;

  const PublishBottomBar({
    super.key,
    required this.isLoading,
    this.onPressed,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0D1117) : Colors.white,
          border: Border(
            top: BorderSide(
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: isLoading ? null : onPressed,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
