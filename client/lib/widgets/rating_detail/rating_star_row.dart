import 'package:flutter/material.dart';

class RatingStarRow extends StatelessWidget {
  final double value;
  final double size;

  const RatingStarRow({
    super.key,
    required this.value,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (i) => Icon(
          i < value.round() ? Icons.star : Icons.star_border,
          size: size,
          color: i < value.round() ? Colors.amber : Colors.grey[400],
        ),
      ),
    );
  }
}
