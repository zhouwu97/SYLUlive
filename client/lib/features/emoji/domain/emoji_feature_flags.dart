class EmojiFeatureFlags {
  const EmojiFeatureFlags(
      {this.customPackImport = true, this.officialPackDownload = true});
  static const production = EmojiFeatureFlags();
  final bool customPackImport;
  final bool officialPackDownload;
  bool get packSharing => false;
  bool get publicPublishing => true;
}
