class DataFreshness {
  const DataFreshness({
    required this.fetchedAt,
    required this.expiresAt,
    required this.isStale,
  });

  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
}
