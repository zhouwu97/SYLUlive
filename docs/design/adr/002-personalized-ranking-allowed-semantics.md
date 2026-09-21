# ADR-002：`personalized_ranking_allowed` 承载「含专业维度的确定性排序」

- 状态：**已接受（Accepted）**
- 日期：2026-09-18
- 决策者：项目负责人（SYLUlive）
- 上游文档：`docs/plans/competition-recommendation-plan.md`（§0.1 D1）、
  `docs/plans/competition-recommendation-algorithm-plan.md`

## Context

「适合我」此前不个性化：专业既没有参与召回（目录侧是「计算机类」这类专业簇标签，
画像侧是教务口径的专业全名，全等判定必然不命中，且不命中就直接淘汰），
也没有参与排序（只比较 `catalog_order`）。

修复需要让「专业匹配」进入排序主体。但目录侧存在一道刻意的治理门：

```text
personalized_ranking_allowed   310/310 全为 false
strong_recommendation_eligible 310/310 全为 false
```

`docs/competition-catalog-v2-runbook.md` 当时写的是「当前目录默认禁止个性化改序和强推荐」。

另外 `server/internal/services/competition_catalog_hasher.go` 对**整个记录结构体**取哈希：

```go
encoded, _ := json.Marshal(normalized)
delete(object, "record_hash")
canonical, _ := json.Marshal(object)
sum := sha256.Sum256(canonical)
```

因此给 `dto.CompetitionCatalogRecord` 增加任何字段，都会让全部 310 条现存 `record_hash` 失配，
连带包哈希失效，必须 schema 版本升级 + 客户端与服务端锁步发布 + 全线重新导出。

## 决策

**不新增字段。** `personalized_ranking_allowed` 自本次起，除原有的「允许个性化改序」语义外，
同时承载一个**窄语义**：

```text
允许对本条赛事按「含专业维度的确定性规则」排序。
```

该窄语义**明确不包含**：

- 不包含 AI 解释（`COMPETITION_AI_EXPLANATION_ENABLED` 独立开关，独立灰度）；
- 不包含强推荐（`strong_recommendation_eligible` 全线保持 false，本次不触碰）；
- 不包含获奖概率或任何预测（治理明令禁止，且无数据支撑）；
- 不包含任何需要训练的模型（排序为纯函数规则，同输入必然同输出）。

配套约束：

1. **翻转范围**：只翻转 `candidate_pool_allowed=true` 的 275 条；
   其余 35 条保持 false。`recommendation_permission_level` 维持 `low`。
2. **禁止直接改库**：翻转通过目录包完成（exporter → 重算 `record_hash`/`package_hash`
   → validate → import → diff → activate）。权威来源是目录包 JSON，
   手改的库值会在下一次激活时被静默回滚。
3. **分两包灰度**：先出「信息科学与工程学院试点包」（实测 109 条），
   再出全量包（275 条）；不与目录激活同时放量。
4. **未授权赛事的行为**：仍可进入结果、可分组、可解释，但**不参与打分排序**，
   按目录序排在已授权赛事之后；若结果集中一条授权赛事都没有，整体回退纯目录序。
   即「未授权 ⇒ 顺序不受画像影响」这一既有断言继续成立。
5. **分值不外露**：内部分值只用于排序；对外只暴露离散档位（`match_tier`）、
   离散依据（`match_basis`）与命中簇（`matched_clusters`）。
   **不得**复用 `personalized_score` / `recommendation_tier` 这两个被
   旧客户端兼容层与治理语境占用的名字。

## 备选方案

1. **新增 `major_ranking_allowed`** —— 否决。哈希是对整个记录结构体取的，
   加字段等于让 310 条记录全部失配，成本与风险比翻转一个已存在布尔值高一个数量级。
2. **不做排序，只做分组** —— 否决。分组正确但顺序仍是目录序，
   用户点开「适合我」看到的首屏与「全部」没有区别（实测未授权态首屏专业相关占比仅 0–3/10），
   等于没有解决用户报告的问题。
3. **用 `strong_recommendation_eligible` 表达排序** —— 否决。
   目录校验器规定「强推荐 ⇒ 必须先开放个性化排序」，两者是单向蕴含关系；
   用强推荐表达排序会连带触发 `permission_level=high`、无阻断码等一整套强推荐语义。

## 影响

- 目录：`personalized_ranking_allowed` 的语义变宽，须以本 ADR + 修订后的 runbook 为准。
- 排序：候选顺序在授权赛事上不再等于目录序，但仍是可复现、可审计、可回滚的确定性顺序
  （分值 → 人工评级 → 重要度 → 目录序 → 赛事编号 → 主键）。
- 回滚有两级：关总开关秒级恢复目录序；目录包 rollback 恢复上一包（连字段翻转一起回退）。
- 治理断言（既有测试）继续成立：`blocked` / `catalog_only` 不出现；
  未授权赛事顺序不受画像影响；`match_score` 不与 `competition_rating` 混用
  （后者在展示层称「人工评级」，与匹配度分区呈现且互不折算）。
