import 'emoji_local_id.dart';
import 'emoji_pack_installation.dart';

class EmojiCreationDraft {
  EmojiCreationDraft(
      {required this.sourcePackId,
      required this.sourceVersion,
      required this.sourceManifestHash,
      required this.attemptId,
      required this.name,
      required this.names,
      required this.coverAssetId,
      required this.iconAssetId,
      this.description = '',
      this.tags = const [],
      this.revisionOf});
  final String sourcePackId, sourceManifestHash, attemptId;
  final int sourceVersion;
  final String? revisionOf;
  String name, description, coverAssetId, iconAssetId;
  List<String> tags;
  Map<String, String> names;
  String get key => '$sourcePackId:${revisionOf ?? 'new'}';

  factory EmojiCreationDraft.fromPack(EmojiPackInstallation pack,
          {String? revisionOf}) =>
      EmojiCreationDraft(
          sourcePackId: pack.packId,
          sourceVersion: pack.version,
          sourceManifestHash: pack.manifestSha256,
          attemptId: newEmojiLocalId(),
          name: pack.name,
          names: {
            for (final asset in pack.manifest.assets) asset.id: asset.name
          },
          coverAssetId: pack.coverAssetId ?? pack.manifest.assets.first.id,
          iconAssetId: pack.iconAssetId ?? pack.manifest.assets.first.id,
          revisionOf: revisionOf);

  Map<String, dynamic> toJson() => {
        'source_pack_id': sourcePackId,
        'source_version': sourceVersion,
        'source_manifest_hash': sourceManifestHash,
        'attempt_id': attemptId,
        'name': name,
        'description': description,
        'names': names,
        'cover_asset_id': coverAssetId,
        'icon_asset_id': iconAssetId,
        'tags': tags,
        'revision_of': revisionOf
      };
  factory EmojiCreationDraft.fromJson(Map<String, dynamic> json) =>
      EmojiCreationDraft(
          sourcePackId: json['source_pack_id'] as String,
          sourceVersion: json['source_version'] as int,
          sourceManifestHash: json['source_manifest_hash'] as String,
          attemptId: json['attempt_id'] as String,
          name: json['name'] as String,
          description: json['description'] as String? ?? '',
          names: Map<String, String>.from(json['names'] as Map),
          coverAssetId: json['cover_asset_id'] as String,
          iconAssetId: json['icon_asset_id'] as String,
          tags: List<String>.from(json['tags'] as List? ?? []),
          revisionOf: json['revision_of'] as String?);
}
