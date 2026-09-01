# PR13 Zero Authority Verification

`zero_authority_verify.py` 是 Release F 的证据门禁。它只读取 Release Commander
在受控环境生成的聚合 JSON，以及已经构建的目录/ZIP/TAR；不会连接生产数据库、日志、
APM 或网络，也不会替代 egress proxy、容器网络策略或主机防火墙。

## 使用

```bash
python scripts/security/zero_authority_verify.py --dry-run --pretty
python scripts/security/zero_authority_verify.py \
  --evidence release-f-evidence.json \
  --artifact release-f.zip --pretty
```

返回码 `0` 只表示输入证据满足脚本契约，返回码 `1` 表示 Gate 失败，返回码 `2` 表示
证据不可读取。输出是脱敏 JSON：只含计数、稳定问题码和发布物相对路径，不得把原始
Email、StudentID、密码、Cookie、Token、请求体或 Canary 实际值写入证据。

## 证据字段

证据必须包含：

- `release.release`、带时区的 `release.recorded_at`、`release.commit_sha`；六个角色签字：`migration_owner`、`backend_owner`、`client_owner`、`dba_data_owner`、`security_reviewer`、`release_commander`。
- `observation_window_hours >= 168`，表示最终 Canary 与 egress 观察至少连续 7 天。
- `metrics` 中的四个零及其相关安全零值全部为数字 `0`。字段名由 `--dry-run` 输出固定契约。
- `canary` 中 Student、Password、Course、Grade 四类 marker 的 `*_matches` 全部为 `0`。
- `routes` 按 `--dry-run` 输出的每个 `method + path` 组合提供独立受控探针记录：退役路由状态码 `410`、`body_read=false`、旧 Handler 调用数 `0`。不得用 `/api/edu/*` 或单个 `/api/edu/bind` 探针代表整个路由族；同一路径的不同方法（例如 `POST /api/edu/bind` 与 `DELETE /api/edu/bind`）也必须分别取证。
- `old_client` 的受控旧 APK 请求全部为 `426`，升级覆盖率和路由族覆盖率为 `100%`，成功业务响应为 `0`。
- `egress.mode=default-deny`、未知必要目的地为 `0`、学校个人系统成功连接为 `0`。允许目的地记录还必须包含外部网络边界、DNS 重校验、Owner、健康检查和未过期到期时间。
- `historical_zero.status` 为 `verified`，或为 `pending_retention_expiry` 并提供未来的 `latest_expiry`。后者只能声明 `Historical Zero - Pending Retention Expiry`，不能写成已完成。

## 发布物扫描

目录、ZIP 和 TAR 会扫描文件名及文本/二进制中的以下残留：

`RemoteAcademicGateway`、`ACADEMIC_GATEWAY=remote`、Server Academic 路由、
`LegacyCampusRegistrationVerifier` 和 `School Device Tool`。任一命中都会阻断；不能
用默认关闭的 feature flag 或永久 allowlist 代替物理删除。

## Egress 记录

`egress_policy.py` 只校验审计记录，不执行网络操作。记录中的 `Authorization`、
`Cookie`、`Body`、`Query secret`、密码、Token 和 StudentID 字段会直接失败。RFC1918、
loopback、IPv6 link-local/unique-local、云元数据、用户控制目的地和未知分类必须为
`deny`。应用代码 allowlist 之外，至少要有一层代理、容器网络策略或主机防火墙证据。

脚本通过后仍需由 Security Reviewer 和 Release Commander 对照原始受控记录签字；它不
把本地 fixture、静态扫描或单次探针结果当作生产事实。
