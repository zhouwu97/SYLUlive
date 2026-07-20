# 客户端个人数据 Gateway 阶段 4A

## 阶段边界

本阶段建立个人数据的唯一只读入口 `PersonalDataGateway`，只接入已经通过
AES-GCM 认证的二课和体测快照。Gateway 面向后续本地 Skill，不面向模型、
页面缓存或任意用户 ID 查询。

本阶段不包含：

- 课表或成绩读取、迁移和展示；
- Tool Calling、权限弹窗或向模型发送个人数据；
- GPA、毕业、竞赛或运动建议计算；
- 自动联网刷新、后台抓取或任何写操作；
- AI 页面或产品入口。

## 数据流

```text
当前认证 App 用户 + 当前来源账号
             |
             v
PersonalAccountContext（构造时固定）
             |
             v
PersonalDataGateway
             |
             +-- ErkeGatewayAdapter
             |        |
             +-- PhysicalGatewayAdapter
                      |
                      v
      AccountScopedSnapshotStore（AES-256-GCM 验证）
                      |
                      v
         最小化、类型化 GatewayResult
```

Gateway 只返回二课/体测概览和新鲜度元数据，不返回 Vault 文件路径、原始
Payload、来源账号、App 用户 ID、密码、Cookie、Token 或密钥。

## 账号与生命周期约束

- `PersonalAccountContext` 必须在创建时同时提供当前 App 用户和来源账号；读取接口
  不接受外部账号参数。
- Gateway 会验证 Vault 的账号指纹；不一致时返回 `accountMismatch`，绝不尝试读取
  其他账号数据。
- 每个 Gateway 注册到 `AccountSessionCleanupCoordinator`。退出或换号时会同步失效，
  已开始但在关闭后返回的读取结果也会被替换为 `closed`。
- 来源账号不匹配时，AES-GCM 快照读取返回空值；Gateway 不回退到其他缓存或网络。

## 失败关闭与新鲜度

`GatewayResult` 的状态包括：

- `available`：已验证且未过期的本地概览；
- `stale`：已验证但过期，保留数据并要求同步；
- `missing`：当前账号没有对应快照；
- `needsRefresh`：没有快照且已有迁移失败/重新同步标记；
- `accountMismatch`、`corrupted`、`unsupported`、`closed`：不返回数据。

密文认证、信封、Schema 或 Payload 格式异常统一映射为 `corrupted`。不会把旧对象、
明文缓存或其他账号数据作为兜底结果。

## 威胁模型

- 同一设备切换 App 账号：Vault 的账号指纹与 Gateway 上下文同时校验。
- 同一 App 账号换来源学号：来源账号指纹校验失败，快照不可读。
- 密文被替换或篡改：AES-GCM 认证失败，Gateway 返回 `corrupted` 且无数据。
- 退出或换号期间异步读取返回：generation 检查阻止旧上下文写回新会话。
- 后续模型或页面越权：阶段 4A 没有模型调用、网络刷新或原始 Payload 出口；后续能力
  必须经由固定 Skill、权限预览和最小化结果协议实现。

## 验证

```bash
cd client
dart format lib/features/ai_runtime/personal_data \
  test/features/ai_runtime/personal_data/gateway/personal_data_gateway_test.dart

flutter analyze --no-fatal-warnings --no-fatal-infos \
  lib/features/ai_runtime/personal_data \
  test/features/ai_runtime/personal_data/gateway/personal_data_gateway_test.dart

flutter test --no-pub \
  test/features/ai_runtime/personal_data/gateway/personal_data_gateway_test.dart

flutter test --no-pub
git diff --check
```

回归测试至少覆盖：加密二课/体测快照、过期标识、来源账号变化、密文篡改、账号指纹
不一致、统一会话关闭和需要重新同步状态。
