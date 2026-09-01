# Account Identity 回填与读切换

本手册只定义 PR3 的部署顺序和脱敏证据。未取得生产变更授权、数据库备份确认和
PR2 预检签字时，只允许运行本地测试或对目标库执行 dry-run；不得执行 `--apply`。

## 发布顺序

1. 部署 Identity Expand 结构和双写代码，保持
   `ACCOUNT_IDENTITY_READ_MODE=legacy`。此时普通 `/api/login` 继续兼容已验证邮箱镜像、
   已验证 StudentID 和 QQ；不得提前宣称已进入 S4。
2. 完成 `docs/migration/account-identity-preflight.md` 的聚合预检、冲突审核和签字，并验证
   数据库备份可读。
3. 先运行默认 dry-run。输出只能保存批次和总计聚合，不得保存邮箱、学号或用户明细。
4. 发布负责人确认 dry-run 后，才可显式提供 `--apply --backup-confirmed`。命令在冲突、
   非法邮箱或对账差异仍非零时返回非零，不能据此切换 S4。
5. 重复运行 dry-run，确认 `would_write=0`，且 Reconcile 的 `missing_identity`、
   `mirror_mismatch`、`identity_user_mismatch` 全部为 `0`。
6. 生成发布证据并由负责人批准后，将 `ACCOUNT_IDENTITY_READ_MODE` 改为 `identity` 再重启。
   Go 服务会在装配登录 Handler 前再次对账；三项任一非零都会拒绝启动。

进入 S4 后，普通 `/api/login` 只查询有效且已验证的 Email Identity，未命中时不会回退
StudentID、QQ 或 `users.email`。迁移期旧账号只能进入独立且有 Sunset 的 `/api/login_edu`。

## 命令

以下命令均从 `server/` 目录执行。`script-sha` 使用实际回填逻辑文件的 SHA-256；输出会在
每一批重复记录该值，便于发布证据关联。

```powershell
$scriptSha = (Get-FileHash -Algorithm SHA256 .\internal\services\account_identity_backfill.go).Hash.ToLower()

# 默认 dry-run，不写数据库
go run ./cmd/backfill_account_identities --script-sha $scriptSha --batch-size 500

# 仅在取得授权并验证备份后执行
go run ./cmd/backfill_account_identities --script-sha $scriptSha --batch-size 500 --apply --backup-confirmed
```

输出字段包括：

- `scope=batch|total|reconcile`：单批、总计或对账摘要。
- `would_write`：dry-run 中符合写入条件的数量；dry-run 的 `written` 固定为 `0`。
- `written`：apply 实际写入数量；apply 的 `would_write` 固定为 `0`。
- `skipped`、`conflicts`、`invalid`：幂等跳过、冲突隔离和非法邮箱数量。
- `missing_identity`、`mirror_mismatch`、`identity_user_mismatch`：S4 启动门禁三项。

命令不自动建表、不自动修改读模式，也不输出 DSN 或任何账号标识。缺少 Expand 结构会直接
失败。apply 失败可能已经提交前序无冲突批次；修复隔离项后重复执行即可，禁止删除已确认的
Identity 数据来“清零”。
