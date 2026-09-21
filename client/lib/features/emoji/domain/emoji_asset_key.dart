/// 表情资源的稳定身份。
///
/// 业务层只应传递此对象或 [serialized]，不要自行 split 字符串。不同资源
/// 来源使用独立命名空间，避免内置贴图、服务端资源和本地导入发生碰撞。
class EmojiAssetKey {
  const EmojiAssetKey({
    required this.namespace,
    this.packId,
    required this.assetId,
  });

  static const Set<String> supportedNamespaces = <String>{
    'unicode',
    'builtin',
    'official',
    'private',
    'local',
  };

  final String namespace;
  final String? packId;
  final String assetId;

  /// 兼容早期只区分 namespace/id 的调用方；新代码优先使用 assetId。
  String get id => assetId;

  /// 使用显式字段拼接，避免调用方重复实现键规则。
  String get serialized => <String>[
        namespace,
        if (packId != null) packId!,
        assetId,
      ].join(':');

  /// 解析统一键。
  ///
  /// `unicode:<unicode>` 与历史私有资源 `private:<serverAssetId>` 不带
  /// packId；builtin/official/local 必须带 packId。组件内部不直接拆分键，
  /// 所有格式校验集中在这里。
  factory EmojiAssetKey.parse(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const FormatException('表情资源键不能为空');
    }
    final parts = normalized.split(':');
    if (parts.length < 2 || parts.length > 3) {
      throw const FormatException('表情资源键格式无效');
    }

    final namespace = parts.first;
    if (!supportedNamespaces.contains(namespace)) {
      throw FormatException('不支持的表情资源命名空间: $namespace');
    }
    final hasPackId = parts.length == 3;
    final packId = hasPackId ? parts[1] : null;
    final assetId = hasPackId ? parts[2] : parts[1];
    _validatePart(assetId, 'assetId');
    if (packId != null) _validatePart(packId, 'packId');

    if (namespace == 'unicode' && packId != null) {
      throw const FormatException('Unicode 资源不允许携带 packId');
    }
    if ((namespace == 'builtin' ||
            namespace == 'official' ||
            namespace == 'local') &&
        packId == null) {
      throw FormatException('$namespace 资源必须携带 packId');
    }
    return EmojiAssetKey(
      namespace: namespace,
      packId: packId,
      assetId: assetId,
    );
  }

  static EmojiAssetKey? tryParse(String? value) {
    if (value == null) return null;
    try {
      return EmojiAssetKey.parse(value);
    } on FormatException {
      return null;
    }
  }

  factory EmojiAssetKey.fromSerialized(String value) =>
      EmojiAssetKey.parse(value);

  static void _validatePart(String value, String name) {
    if (value.trim().isEmpty || value.contains(':')) {
      throw FormatException('表情资源 $name 无效');
    }
  }

  @override
  bool operator ==(Object other) {
    return other is EmojiAssetKey &&
        other.namespace == namespace &&
        other.packId == packId &&
        other.assetId == assetId;
  }

  @override
  int get hashCode => Object.hash(namespace, packId, assetId);

  @override
  String toString() => serialized;
}
