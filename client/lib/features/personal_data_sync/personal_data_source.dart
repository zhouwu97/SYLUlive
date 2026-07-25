/// 校园 Agent 与客户端共享的个人数据来源，枚举值是稳定的 API wire 值。
enum PersonalDataSource {
  serverSnapshot,
  deviceEncryptedCache,
  remoteEduFetch,
  userUploadedSnapshot,
  publicDatabase,
  knowledgeBase,
  none;

  /// 保留旧名称，避免既有本地个人 AI 的调用方在迁移期间中断。
  @Deprecated('请使用 PersonalDataSource.deviceEncryptedCache')
  static const PersonalDataSource localEncryptedVault =
      PersonalDataSource.deviceEncryptedCache;
}

extension PersonalDataSourceWireValue on PersonalDataSource {
  String get wireValue => switch (this) {
        PersonalDataSource.serverSnapshot => 'server_snapshot',
        PersonalDataSource.deviceEncryptedCache => 'device_encrypted_cache',
        PersonalDataSource.remoteEduFetch => 'remote_edu_fetch',
        PersonalDataSource.userUploadedSnapshot => 'user_uploaded_snapshot',
        PersonalDataSource.publicDatabase => 'public_database',
        PersonalDataSource.knowledgeBase => 'knowledge_base',
        PersonalDataSource.none => 'none',
      };

  static PersonalDataSource fromWireValue(String value) => switch (value) {
        'server_snapshot' => PersonalDataSource.serverSnapshot,
        'device_encrypted_cache' => PersonalDataSource.deviceEncryptedCache,
        'remote_edu_fetch' => PersonalDataSource.remoteEduFetch,
        'user_uploaded_snapshot' => PersonalDataSource.userUploadedSnapshot,
        'public_database' => PersonalDataSource.publicDatabase,
        'knowledge_base' => PersonalDataSource.knowledgeBase,
        'none' => PersonalDataSource.none,
        _ => throw FormatException('未知个人数据来源：$value'),
      };
}
