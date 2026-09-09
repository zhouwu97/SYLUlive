# Catalog 2.2 发布与回滚手册

本手册适用于 `sylulive-competition-catalog/2.2`。生产服务只接收 JSON，
不得直接读取 Excel、公式缓存或本地工作簿。

## 发布边界

- Go 决定赛事是否进入公开目录和候选池。
- 当前目录默认禁止个性化改序和强推荐。
- Hy3 只解释 Go 已批准且已排序的候选。
- `draft` 或 `production_load_allowed=false` 的包不得激活。
- 数据库操作前必须完成备份，并验证备份非空且可读。

## 功能开关

第一阶段建议：

```text
COMPETITION_CANDIDATE_ENGINE_V2_ENABLED=true
COMPETITION_CATALOG_V2_ENABLED=false
COMPETITION_AI_EXPLANATION_ENABLED=false
```

需要暂存 Catalog 时才开启 `COMPETITION_CATALOG_V2_ENABLED`。AI 解释必须在候选链路
稳定后单独灰度，不能与目录激活同时放量。

## 离线导出

在仓库根目录运行：

```powershell
python tools/competition_catalog/export_catalog_v2.py input.xlsx catalog.json
python tools/competition_catalog/validate_catalog_v2.py catalog.json
```

离线校验只用于提前发现问题。Go 服务仍会独立复算所有 `record_hash` 和
`package_hash`，不得跳过服务端校验。

## 补录已核验报名日程

`tools/competition_catalog/data/verified_schedules_2026.json` 保存已核验的当届日程、
校内/省赛/全国适用范围和官方通知。它是增量事实清单，不能直接作为目录包激活。
第二来源为辽宁省大学生创新创业管理共享平台（`https://cxcy.upln.cn/match`），
核对时选择当届年度和“全部”。来源中的 `registration_window` 保留平台原始时刻；
更早的校内截止仍优先。同属省赛而截止不一致的记录保留双方说明、标记 `pending`，
在确认延期或补录阶段前不生成统一截止提醒；单赛道日期不能推广为整个赛事日期。
当届日程缺失时，可使用对应全国赛、辽宁赛区或校内选拔的最近可核验往年记录：保留原始 `season_year`，
`time_status=historical`，日期仅写入展示文字和来源证据，不写入报名/比赛时间戳。
优先采用2025届，缺失时采用2024届，并明确标注参考年份。`fallback` 只补缺口，
不会覆盖已有当届安排或冲突说明；后续当届日程核实后通过正常目录合并替换参考。

```powershell
python tools/competition_catalog/merge_schedules.py fallback current-schedules.json historical-schedules.json combined-schedules.json
```

使用管理员保存或导出的完整活动目录 JSON 合并，不能使用缺少治理字段的公开赛事接口响应：

```powershell
python tools/competition_catalog/merge_schedules.py merge catalog.json tools/competition_catalog/data/verified_schedules_2026.json catalog-schedules.json --dataset-version 2026.09.08-schedules-1
python tools/competition_catalog/validate_catalog_v2.py catalog-schedules.json
```

报名入口、步骤、材料和公开校内联系方式保存在
`tools/competition_catalog/data/verified_registration_2026.json`。合并时追加
`--registration tools/competition_catalog/data/verified_registration_2026.json`，
指引写入现有比赛说明并保留原介绍；重复合并只更新指引区段。
报名方式已核验不代表报名仍开放，也不代表日程已补齐。
当届报名方式缺失时，可使用 `status=historical`、实际 `season_year` 的往年指引，
详情明确显示旧届年份，保留旧链接作为参考，不将其提升为当前官网入口，
也不覆盖已存在的当届报名指引。

校内信息使用[创新创业学院通知公告](https://cxcyxy.sylu.edu.cn/tztg.htm)核验。
学生提交、学校审核推荐、省平台备案分别保留，校内截止优先于较晚的平台开放窗口。
通知年份矛盾或同阶段日期冲突时保留待核状态，不自行改年或推算日期。
日程单条 `verified_on` 表示该条最近核验日期，未填写时沿用文件级日期。

合并保留评级、推荐权限、阻断项和发布门禁；已有日期冲突时停止并要求复核。
分赛道安排不强行合并为统一截止，未核实项目不填写推测日期。仅公布日期的通知，
服务按北京时间截止日结束计算；有明确时刻的通知保留原时刻，界面优先展示原通知范围说明。
合并后仍须按下文备份、导入、检查 diff 和激活，且先部署支持日期边界处理的服务端版本。

完整公开快照（含 `total` 和去重后的全部 `items`）可用于统计覆盖率，但不能用于发布：

```powershell
python tools/competition_catalog/merge_schedules.py audit public-events.json tools/competition_catalog/data/verified_schedules_2026.json coverage.json
```

审计命令也可追加同一 `--registration` 参数，同时列出报名指引缺口。
`reviewed` 包含待核及往年记录，`event_text_count` 包含待确认说明；
两者均不是完整率。审计结果不能作为发布包。没有服务器或完整目录时，可先完成
本地补录与校验，保留后续导入；Git 提交本身不会把这些信息发布到线上。

## 数据库备份门禁

1. 只读确认生产数据库类型、连接方式、库名和磁盘余量。
2. 使用数据库原生工具生成带时间戳的完整备份。
3. 校验备份文件存在、大小大于 0，并能列出结构或完成隔离恢复检查。
4. 记录备份路径、SHA-256、数据库类型和备份时间。
5. 任一检查失败时停止迁移、激活和服务重启。

备份文件不得提交到 Git，也不得写入公开日志。

## 管理接口

所有接口都要求管理员身份：

```text
POST /api/admin/competition-catalog/packages/validate
POST /api/admin/competition-catalog/packages/import
GET  /api/admin/competition-catalog/packages
GET  /api/admin/competition-catalog/packages/:id
GET  /api/admin/competition-catalog/packages/:id/diff
POST /api/admin/competition-catalog/packages/:id/activate
POST /api/admin/competition-catalog/packages/:id/rollback
```

`validate` 和 `import` 的请求体都是完整 Catalog JSON。导入后先检查包详情和 diff，
不得直接激活。

## 激活检查

激活前必须同时满足：

```text
publish_status=published
production_load_allowed=true
validation_status=passed
包哈希与全部记录哈希复算一致
不存在 P0 阻断
数据库备份已验证
```

激活在单个数据库事务内执行：锁定目录包、写入赛事、归档新包未包含的旧 Catalog
赛事、切换活动包并写审计。失败必须保持原活动包和赛事状态不变。

激活后核对：

- 活动包只有一个；
- 普通目录仍只返回已发布且允许展示的赛事；
- `/api/user/competitions/candidates` 返回新 `dataset_version`；
- 候选不包含 `personalized_score`，且目录禁止排名时顺序不受画像影响；
- 服务健康检查、错误率和审计记录正常。

## 回滚

以当前活动包 ID 调用：

```text
POST /api/admin/competition-catalog/packages/:current_id/rollback
```

服务会在事务中恢复 `previous_package_id` 指向的上一包，并重建对应赛事状态。回滚后
重新核对活动包唯一性、目录、候选版本和 `catalog_rollback` 审计记录。

紧急情况下可先关闭：

```text
COMPETITION_AI_EXPLANATION_ENABLED=false
COMPETITION_CANDIDATE_ENGINE_V2_ENABLED=false
```

关闭 AI 后规则候选仍应可用。关闭候选 v2 时，旧 `/fit` 适配器也不得恢复偏好改序或
返回伪精确分数。
