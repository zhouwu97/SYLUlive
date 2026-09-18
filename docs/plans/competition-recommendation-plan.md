# 竞赛中心「适合我」推荐优化计划

> 状态：**v2 待评审（未写任何代码）** —— 三项前置决策已给结论（§0.1），
> 数据结构方案已按结论收敛（§6.2 取消三个新增字段），验收口径已按测试基线修正（§10.1）。
> 范围：`server/internal/competitioncontext`、`server/internal/services/competition_candidate_engine.go`、
> `server/internal/handlers/competition_candidate*.go`、`client/lib/screens/competition/*`、
> `client/lib/widgets/competition/*`
> 目标：让「适合我」按用户专业做真实的个性化匹配与排序，而不是退化成一份与专业无关的目录列表。
> 阅读顺序建议：§0 → §0.1（决策）→ §2（原因）→ §3.6（实现契约）→ §7（阶段与验收）→ 附录 B（待教务核对）。

---

## 0. 结论摘要

一句话诊断：**「适合我」不是坏了，而是从未真正实现个性化。**当前链路做了「资格过滤 + 按目录序输出」，
专业既没有参与召回（因为标签口径对不上，且不命中即淘汰），也没有参与排序（`competitionCandidateLess`
只比较 `catalog_order`），偏好打分函数 `matchCompetitionPreference` 是仅被测试引用的死代码。

三个必须先拍板的前置决策，否则第 2 阶段无法落地。**推荐结论与理由见 §0.1**。

| 编号 | 决策点 | 结论 | 为什么必须现在定 |
|---|---|---|---|
| D1 | 个性化排序的治理开关怎么开 | **不新开字段**，复用 `personalized_ranking_allowed` | 目录快照中 `personalized_ranking_allowed` 与 `strong_recommendation_eligible` **310/310 全为 false**，`docs/competition-catalog-v2-runbook.md` 明文写「当前目录默认禁止个性化改序和强推荐」。这不是 bug，是刻意的策略门。不修订契约就只能做到「按专业分组」，做不到「按专业排序」。 |
| D2 | 学校专业字典（教务标准专业名清单）由谁提供 | **教务名册 + 13 学院 × 53 簇映射矩阵**，冷启动不等排期 | 目录侧是「专业类/方向词」，画像侧是教务标准专业名，两者之间必须有映射表，且必须基于真实专业清单，不能靠猜。 |
| D3 | 目录侧 53 个标签可否修订 | **本期只修三类必须修的，且与 D1 合并成一次目录重导出** | 改标签要重算全包 hash，与 D1 走同一条发布路径；分两次做等于把高风险操作做两遍。 |

### 0.1 三项决策的推荐结论与理由

#### D1 — 不新开字段，复用 `personalized_ranking_allowed`

**结论：把 `candidate_pool_allowed=true` 的 275 条赛事翻转为 `personalized_ranking_allowed=true`；其余 35 条保持 false；`strong_recommendation_eligible` 全线保持 false 不动。**

原先设想的「新增 `major_ranking_allowed`」被否决，理由是核查 `server/internal/services/competition_catalog_hasher.go:16-36` 后发现：

```go
encoded, _ := json.Marshal(normalized)   // 整个 CompetitionCatalogRecord 结构体
delete(object, "record_hash")
canonical, _ := json.Marshal(object)
sum := sha256.Sum256(canonical)
```

`record_hash` 是对**整个记录结构体**取哈希。给 `dto.CompetitionCatalogRecord` 加任何一个字段，都会让**全部 310 条现存 `record_hash` 失配**，连带包哈希失效，必须：schema 版本升级（2.2 → 2.3）+ 服务端与客户端锁步发布 + 全线重新导出。而翻转一个**已存在字段的布尔值**，走的是仓库里已经演练过的标准目录重导出流程（validate → import → diff → activate），不动 schema，旧包仍可被旧版本代码校验。两者都要重导出，但代价与风险差一个量级。

复用不牺牲解耦，因为既有校验规则已经提供了所需的语义边界
（`server/internal/services/competition_catalog_validator.go:110-127`）：

| 既有约束 | 作用 |
|---|---|
| 未进候选池 → 不得开放个性化排序（`:111-113`） | 翻转只对 275 条候选池内赛事生效，与治理主线一致 |
| 强推荐 → 必须先开放个性化排序（`:122-124`） | **单向蕴含**：翻转排序**不会**连带翻转强推荐 |
| 强推荐 → 权限必须 `high` 且无阻断码（`:118-127`） | 强推荐保持 false，本次不触碰任何强推荐语义 |

即「排序」与「强推荐」天然解耦，无需新字段。实测支撑：

- 275 条候选池赛事 `recommendation_permission_level` **全部为 `low`**、`ai_mode` 全部为 `candidate_explanation`、`blocker_codes` 非空数为 **0**、`strong_recommendation_eligible` 全部 false；
- 因此翻转后不触发任何既有 validator 规则，`low` + `ranking=true` 是合规组合。

**必须遵守的两条操作纪律**

1. **禁止直接用 SQL 改库。** 权威来源是目录包 JSON（`tools/competition_catalog/`），
   导入激活会覆盖 DB 值 —— 手改的字段会在下一次激活时被静默回滚。
2. **分两包灰度，不要一次全量。** 先出「试点包」只翻转信息科学与工程学院相关赛事
   （实测 109 条），验证排序上线后卡片效果与埋点，再出全量包。这与 runbook
   「不能与目录激活同时放量」的要求一致。

**必须补一份 ADR**，明确记录：`personalized_ranking_allowed` 在本次之后同时承载
「含专业维度的确定性排序」这一窄语义，且该能力**不含** AI 解释、不含强推荐、不含获奖预测；
同时修订 `docs/competition-catalog-v2-runbook.md:9` 与 `:141` 两处表述，
并把「目录禁止排名时顺序不受画像影响」改为「允许排名时顺序必须可复现、可审计」。

#### D2 — 教务名册为准，但冷启动不等排期

**结论：三层来源，优先级明确，且缺映射必须可见。**

| 优先级 | 来源 | 标记 | 说明 |
|---|---|---|---|
| 1 | 教务/学籍专业名册（一次性 Excel 即可，**不需要接口对接**） | `source=roster` | 唯一权威来源 |
| 2 | 已核验用户画像去重（`AdminCompetitionAudienceOptions`，`competition.go:681` 已有此查询） | `source=user_derived` | 冷启动用；真实但覆盖不全、可能有拼写噪声 |
| 3 | 13 学院 × 53 簇映射矩阵，由各学院教务员/教学秘书各填一张表 | `source=manual` | **真正的工作量在这里**，一院一张表，成本极低，不必等排期 |

三条硬要求：

- **必须有别名表。** `users.edu_major` 是自由文本 `varchar(100)`，
  `normalizeAcademicName`（`competition.go:397-400`）只做去标点、转小写、合并空格，
  挡不住「计算机科学与技术(嵌入式)」这类变体。需要 `alias → canonical` 映射。
- **必须有 `major_cluster_override`**，让用户手动纠正系统推断。这是唯一能兜住长尾专业的机制。
- **缺映射不得静默落入通用池。** 否则「某些专业永远匹配不到」会以完全静默的方式复发
  —— 也就是现在这个 bug。覆盖率报告必须能列出「哪些专业没有映射」。

#### D3 — 本期不动标签口径，但三类必须和 D1 合并成一次重导出

**结论：画像侧单向归一化（本期），目录标签规范化列为 catalog 2.3 的技术债。**

不动标签口径的理由：53 个标签虽命名不规范，但**已经能表达「这个赛事适合谁来」**，
只是粒度不均；而画像侧单向归一化改动小、可回滚、不触碰已激活的治理状态。

必须本期修的三类（与 D1 合并进同一次目录重导出）：

| 类别 | 实测规模 | 处理 |
|---|---|---|
| 明显错配 | 至少 1 例（全国大学生化学实验创新设计大赛 → 艺术设计类） | 修正，走 diff 复核 |
| `eligible_entry_years` 缺口 | 263/310 为空 | 能补则补；补不了的接受「不限年级」并标注 |
| 「-相关」类模糊标签 | **14 个**（另有 `工科相关专业`，合计 15 个） | 主要噪声源：数字媒体相关 45、工程设计相关 29、生命健康相关 25、人文社科相关 24、思想政治教育相关 24、集成电路相关 22；长尾 8 个仅出现 1–2 次。落成具体专业类，或显式标记为「宽泛适配」并降低匹配权重 |

> **对上一版计划的一处更正：** 此前提出「通用池里可能出现适用年级=研究生的赛事推给本科生」，
> 实测**不成立** —— `target_audience` 中提及研究生的赛事**全部**都有 `eligible_entry_years`
> （如 `["研究生","已获研究生入学资格的本科生"]`），年级门对它们是生效的。
> `47/310` 的缺口是**覆盖面**问题（多数赛事本身不限年级），不是正确性问题，风险等级下调。


---

## 1. 现状与调用链

### 1.1 主链路

```
客户端 competition_center_screen.dart:327-335
  「适合我」 → GET /user/competitions/candidates      （其余筛选 → /competitions/events）
        ↓ 路由注册 cmd/main.go:1524-1529
        仅当 cfg.CompetitionCandidateEngineV2Enabled 为 true 时注册
        ↓
  handlers/competition_candidate.go:29  ListCompetitionCandidates
        ↓
  services/competition_candidate_engine.go:55  BuildCandidates
        ├── 1. competitioncontext.Builder  读画像（专业/学院/年级 + 偏好 + 经历）
        ├── 2. ProfileReady 为 false → 直接返回空 groups（无原因码）
        ├── 3. competitionscope.ApplyCandidate  治理门（published / search_display_allowed / candidate_pool_allowed）
        ├── 4. buildCompetitionCandidate  资格门 + 分组 + 硬淘汰
        └── 5. competitionCandidateLess   排序：catalog_order → competition_id → id
```

兼容路由 `GET /competitions/fit`（`handlers/competition.go:677`）走同一个引擎，输出前会
`delete(personalized_score)` / `delete(recommendation_tier)`（`competition_candidate.go:140-151`）。

### 1.2 目录数据实测（`tmp/competition-schedule/public-events.json`，310 条已发布赛事）

| 指标 | 实测值 |
|---|---|
| `eligible_majors` 非空 | 259 / 310 |
| `eligible_colleges` 非空 | 275 / 310 |
| `eligible_entry_years` 非空 | **47 / 310**（年级门基本失效） |
| 专业标签去重后 | **53 个**，且是「专业类/方向词」：计算机类 81、工业设计 71、材料类 55、机械类 51、数字媒体相关 45、智能科学类 37… |
| 学院标签去重后 | 13 个，与学校真实学院名一致（信息科学与工程学院 109…） |
| `personalized_ranking_allowed` | **false × 310** |
| `strong_recommendation_eligible` | **false × 310** |
| `recommendation_permission_level` | low 275 / blocked 35 |
| `candidate_pool_allowed` | true 275 / false 35 |
| `tags` 去重后 | 22 个（省级 173、国家级 137、智能制造 56、计算机 42…）**完全未参与匹配** |
| `major_fit_summary_public` | 310 条全有，但全部是模板话术（「主要适配 X、Y…具体以当届要求为准」），无结构化信号 |

### 1.3 复刻当前引擎逻辑的匹配模拟（用真实教务口径专业名）

| 用户专业（教务口径） | major_match | college_match | general | 被丢弃 | 合计 |
|---|---|---|---|---|---|
| 计算机科学与技术 | **0** | 7 | 31 | 272 | 38 |
| 自动化 | **0** | **0** | 31 | 279 | 31 |
| 机械设计制造及其自动化 | **0** | 2 | 31 | 277 | 33 |
| 工业设计 | 60 | 0 | 31 | 219 | 91 |
| 软件工程 | 34 | 7 | 31 | 238 | 72 |
| 环境设计 | 34 | 0 | 31 | 245 | 65 |
| 会计学 | 25 | 5 | 31 | 249 | 61 |
| 英语 | 25 | 0 | 31 | 254 | 56 |
| （对照组）直接填标签词「计算机类」 | 71 | 7 | 31 | 201 | 78 |

同一所学校、不同专业，召回量从 **31 到 91** 不等。计算科学与技术、自动化、机械设计制造及其自动化
这三个**最主流的专业**恰好是 0 ——这就是「基本不可用」的量化形态。

---

## 2. 「适合我」不可用的原因分析

按影响面排序，每条给出证据、影响与修复归属阶段。

### P0-1 专业标签口径错位 + 精确相等判定（决定性原因）

- 证据：`services/competition_candidate_engine.go:335-343` `containsCandidateValue` 做的是
  `TrimSpace(ToLower(x)) == TrimSpace(ToLower(y))`，即**全等**。
  而目录侧值是「计算机类」「智能科学类」「数字媒体相关」，画像侧是 `users.edu_major` 的教务标准专业名。
- 影响：259 条带专业范围的赛事中，绝大多数无法命中 → 从上表可见主流专业 major_match = 0。
- 归属：阶段 1。

### P0-2 专业不命中即硬淘汰（比 P0-1 更致命）

- 证据：`competition_candidate_engine.go:247-261`

  ```go
  if len(majors) > 0 {
      if !containsCandidateValue(majors, context.Major) {
          return dto.CompetitionCandidateDTO{}, false   // 直接丢弃
      }
      ...
  }
  ```

- 影响：**赛事因为标注了专业范围反而被淘汰**，连 `general_match` 都进不去。这是反向激励：
  数据越完善、被推荐的机会越小。实测 dropped 219–279/310。
- 归属：阶段 1（核心改动：硬淘汰 → 降级）。

### P0-3 排序没有任何个性化（用户需求的核心缺口）

- 证据：`competition_candidate_engine.go:325-333` `competitionCandidateLess` 只比较
  `CatalogOrder → CompetitionID → ID`。偏好（目标/方向/技能/角色/每周投入）**从未进入排序**。
- 证据：`handlers/competition_preference_matching.go` 里的 `matchCompetitionPreference` 是唯一实现了
  打分（专业 40/学院 32/通用 24 + 偏好 + 时间 + 价值）的函数，但全仓检索显示**只有它自己的测试引用它**，
  生产链路无调用点 —— 死代码。
- 影响：即便召回修好，顺序仍与专业无关。
- 归属：阶段 2。

### P0-4 治理契约给「个性化排序」上了锁（前置决策，非技术问题）

- 证据：310/310 赛事 `personalized_ranking_allowed=false`；
  `competition_candidate_engine.go:289` `PersonalizedRankingAllowed: event.PersonalizedRankingAllowed && !legacyCompatible`；
  `docs/competition-catalog-v2-runbook.md:9` 「当前目录默认禁止个性化改序和强推荐」、
  `:141` 「候选不包含 `personalized_score`，且目录禁止排名时顺序不受画像影响」。
- 证据：`handlers/competition_recommendation_snapshot.go:103` 强制 `event.PersonalizedScore = nil`。
- 影响：直接上线排序会违反既有治理约定与 runbook，并且 AI 行动草稿快照的一致性校验会失效。
- 归属：阶段 2 前置，需要 ADR + 目录回填（见 §6.4）。

### P1-5 功能开关默认关闭，前端调用的是一个可能不存在的路由

- 证据：`config/config.go:488` `envBool("COMPETITION_CANDIDATE_ENGINE_V2_ENABLED", false)`，
  路由仅在 true 时注册（`cmd/main.go:1524`）；而客户端「适合我」固定打 `/user/competitions/candidates`
  （`competition_center_screen.dart:329`），不会回退到永久注册的 `/competitions/fit`。
- 影响：环境未配置该变量时，「适合我」直接 404 → 界面报「比赛加载失败」，即"点了没用"。
- 归属：阶段 0。

### P1-6 画像未就绪时被静默弹回「全部」，且无任何原因反馈

- 证据：`competition_center_screen.dart:295-297`

  ```dart
  if (!_profileReady && _studentFocusFilter == 'fit') {
    _studentFocusFilter = 'all';   // 静默切换，用户看不到任何解释
  }
  ```

- 证据：画像就绪条件很严（`competitioncontext/context.go:79-80`）：
  `HasVerifiedAcademicIdentity` **且** EntryYear / College / Major 三项全非空；不满足时
  `BuildCandidates` 直接返回空 groups（`competition_candidate_engine.go:72-74`），无 reason code。
- 影响：用户点「适合我」→ 选中态消失或空白 → 感知为"不可用"。这是"基本不可用"的**主观来源**。
- 归属：阶段 0（交互）+ 阶段 1（返回结构化原因码）。

### P1-7 「为什么进入候选」弹窗里 6/10 个维度永远是「尚未确认」

- 证据：`buildCompetitionCandidate` 初始化 `dimensions` 时把
  `Goal / Direction / Skill / Role / Time / Training` 全部硬编码为 `"unknown"`，
  而 `competition_match_reason_sheet.dart:239-253` 把 unknown 渲染为「尚未确认」。
- 影响：用户点开解释弹窗，看到一半以上维度是空白 —— 直接摧毁信任感，也削弱了「个性化」的说服力。
- 归属：阶段 1（补算）→ 阶段 2（叠加分项明细）。

### P2-8 数据质量与字段缺失

- 专业标签存在明显错配：`全国大学生化学实验创新设计大赛` 的 `eligible_majors` 是
  `["视觉传达设计","环境设计","产品设计","动画","工业设计","数字媒体相关"]`（艺术类），
  说明该字段有批量复制/人工失误，且当前**没有任何一致性校验**。
- `eligible_entry_years` 仅 47/310 有值 → 年级门形同虚设；通用池里已出现
  「适用年级：研究生、已获研究生入学资格的本科生」的赛事（如中国研究生智能建造创新大赛），
  可能推给本科生。
- 全库无「专业 → 专业类/方向」映射表，也无专业字典表，画像侧的 `edu_major` 是自由文本。
- 归属：阶段 1（复核 + 回填）、阶段 3（看板与纠错闭环）。

### P2-9 前端分页可能提前判定到底

- 证据：`competition_center_screen.dart:389`
  `_hasMore = items.length >= _pageSize && _events.length < total;`
  而 `_events` 在跨页去重（L363-367），代码注释也承认「去重后的 `_events.length` 永远追不上 total」。
- 影响：结果条数多但重复项多时，可能出现过早停止加载（或反之无限翻页空转）。
- 归属：阶段 1（后端补 `has_more` 字段，前端直接信任）。

---

## 3. 专业与竞赛的匹配模型设计

### 3.1 三层标签体系

```
Layer 0  标准专业（canonical major）
         users.edu_major 的教务口径，如「计算机科学与技术」「机械设计制造及其自动化」
         ↓ 映射（本计划新建，人工复核）
Layer 1  专业簇（major cluster）—— 匹配的中介层，词表以目录侧 53 个标签为准
         如「计算机类」「软件工程」「机械类」「工业设计」「数字媒体相关」…
         ↓ 交集运算
         赛事侧 competition_events.eligible_majors（已是簇口径，无需再归一化）
Layer 2  方向/技能/角色（对齐客户端已有受控词表，作为桥接与偏好信号）
         competitionDirectionOptions 11 项、competitionSkillOptions 12 项、competitionRoleKeywords 7 项
```

设计理由：目录侧 53 个标签已经过治理审核、已激活在线上，且支持「一个专业类覆盖多个专业」的用法；
让画像侧单向归一化到目录词表，是改动面最小、可回滚的方案（对应决策 D3 的默认路径）。

### 3.2 专业簇词表（以实测目录标签为基准）

以 `eligible_majors` 的实际取值为准建立簇词表，共 53 项，按学校 13 个学院归组。节选：

| 学院 | 目录侧出现的专业簇标签 |
|---|---|
| 信息科学与工程学院 | 计算机类、软件工程、网络工程、数据科学类、智能科学类、电子信息类、通信工程、集成电路相关、微电子相关 |
| 自动化与电气工程学院 | 自动化类、自动化相关、电气工程类、机器人工程 |
| 机械工程学院 / 装备工程学院 | 机械类、车辆工程、工业设计、工程设计相关 |
| 材料科学与工程学院 | 材料类、生命健康相关 |
| 艺术设计学院 | 视觉传达设计、环境设计、产品设计、动画、工业设计、数字媒体相关 |
| 经济管理学院 | 电子商务、市场营销、工商管理类、工商管理、会计学、金融学、经济学类、财务管理、国际经济与贸易 |
| 理学院 | 数学类、数学与应用数学、统计学类、应用化学 |
| 环境与化学工程学院 | 环境工程、化学工程与工艺、应用化学 |
| 外国语学院 / 马克思主义学院 | 英语、俄语、翻译、人文社科相关、思想政治教育相关 |
| 创新创业学院 | （通用，见 general 池） |

### 3.3 映射规则

1. **精确名优先**：`canonical major == 某个簇标签` → 直接映射（如 `软件工程`、`工业设计`、`会计学`、`英语`、
   `环境设计` 都是「同名即命中」的那批，实测召回最好）。
2. **归口类映射**：`X 类` 兜底（`计算机科学与技术 → 计算机类`、`机械设计制造及其自动化 → 机械类`）。
   一个专业可映射到多个簇（如 `工业设计 → [工业设计, 机械类, 数字媒体相关]`）。
3. **学院级兜底**：映射缺失时，用 `users.edu_college` ∩ `eligible_colleges` 命中，落入 `college_match`
   分组并降低分值（不放行到 major_match，避免虚高）。
4. **方向标签桥接**：`competition_events.tags`（22 词表）与 `primary_category.slug`（10 类）作为
   第三级桥接，只在 1–3 都未命中时提供少量分数，不改变分组。
5. **来源标记**：每条映射带 `source ∈ {roster, user_derived, manual}`，记录在 `academic_majors` 上；
   低可信映射只降权不主导。覆盖率报告需能列出「哪些专业尚无映射」。

### 3.4 匹配流程：硬门 → 降级 → 软分

**硬门（命中即淘汰，保留极少数）**

| 门 | 条件 | 说明 |
|---|---|---|
| E1 治理 | `status=published` ∧ `search_display_allowed` ∧ `candidate_pool_allowed` | 已由 `competitionscope.ApplyCandidate` 实现，保持 |
| E2 年级 | `eligible_entry_years` 非空时校验 | 保留；非空仅 47 条，其余放行并在卡片标注「年级范围待确认」 |
| E3 时间 | 报名已截止 | 按 D6 产品决策：默认过滤，或置底并标注 |

**降级（**本项目最关键的改动**）**

- 专业簇未命中 **不再淘汰**：改为
  - 专业簇命中 → `major_match`「专业直接相关」
  - 学院命中 → `college_match`「学院范围相关」
  - 都未命中 → `general_match`「通用候选」，并给较低基础分
- 唯一例外：赛事明确写了排除范围（未来若引入 `excluded_*` 字段）才允许淘汰。

**软分（排序用，满分 100）**

| 维度 | 上限 | 计分规则 | 设计理由 |
|---|---|---|---|
| M 专业匹配 | 46 | 专业簇交集命中 **40**；学院命中 **26**；仅 tag/类别桥接 **16**；纯通用 **8**（互斥取最高，不叠加）；`eligible_majors` 直接含教务专业全名再 **+6** | 这是用户明确提出的一级需求，权重最高 |
| P 偏好 | 22 | 方向 8/个（≤12）、技能 4/个（≤8）、角色 5/个（≤10），合计封顶 22 | 沿用 `competition_preference_matching.go:48` 已验证的分值骨架，避免另起一套 |
| G 目标 | 12 | 复用现有分支：resume/postgraduate 看评级与学校认定、ability 看是否命中方向、exploration 恒定给分 | 逻辑已在 legacy 函数中验证过，迁移即可 |
| T 时间投入 | 10 | `weekly_hours ≥ 估计投入` 给 8；长期训练偏好一致给 4，封顶 10 | 复用 `estimatedCompetitionWeeklyHours` |
| V 赛事价值 | 10 | `competition_rating` S/A 给 4、B+/B 给 2、B-/C 给 1；`importance_score` ≥80 加 2、≥50 加 1，封顶 | 与人工评级保持独立展示，不得混同 |
| 惩罚项 | −15 | 时间待核实 −4；已截止 −8；高风险投入标签且用户投入偏低 −6；证据等级 B2 −3 | 只降权不淘汰，保证召回 |

**分档（Tier）**

| 分值 | 分档 | 前端文案 |
|---|---|---|
| ≥ 72 | `strong` | 高度匹配 |
| 55–71 | `suitable` | 较为匹配 |
| 40–54 | `explore` | 可以探索 |
| < 40 | 不展示在「适合我」 | — |

> 命名强制要求：新字段必须叫 `match_score` / `match_tier`，**不得复用 `recommendation_tier` 或
> `personalized_score`**。前者已被旧客户端兼容占用、且在治理语境中指「推荐等级」；
> 后者被 runbook 明确禁止出现在候选响应中。混用会造成治理语义污染（对应 P0-4）。

### 3.5 可解释性字段（写入 DTO）

- `match_basis`：`major_cluster` | `college` | `tag_bridge` | `general`
- `matched_clusters`：用户侧命中的专业簇，如 `["计算机类"]`
- `matched_majors`：赛事侧被命中的标签，如 `["计算机类","软件工程"]`
- `score_breakdown`：`{major, preference, goal, time, value, penalty}` 六项明细
- `match_reason_text`：自然语言，如「你的专业属于计算机类，该赛事面向计算机类开放」
- `algorithm_version`：如 `major-match-v1`，用于埋点与离线评估对齐

### 3.6 边界情况与确定性规则

这一节是**实现契约**：每种边界只允许一种行为，否则不同人实现出的结果会不一致，
而「确定性可复现」是本次上线的治理前提。

| 编号 | 边界情况 | 规定行为 | 理由 |
|---|---|---|---|
| B1 | 用户专业在 `academic_majors` 中**无映射** | 按 §3.3 规则 3 降级到学院匹配；学院也未命中则落 `general_match`；**并在响应中带 `reason_code=cluster_unmapped`** | 不能静默落通用池，否则「某专业永远匹配不到」会以无声方式复发（就是当前的 bug） |
| B2 | 一个标准专业映射到**多个簇** | 全部参与交集；命中任一个即 `major_cluster`；`matched_clusters` 返回**全部命中项**，M 分**不叠加**（互斥取最高 40） | 多簇是精度手段，不是加权手段，叠加会让宽口径专业虚高 |
| B3 | 赛事 `eligible_majors` **为空** | 不参与专业判定，不淘汰；走学院判定；学院也空则 `general_match`，M 取纯通用分 8 | 35/310 是这种情况，是合法状态而非数据缺失 |
| B4 | 赛事 `eligible_colleges` 非空但用户学院**不在其中** | **不淘汰**，降级 `general_match` | 与 P0-2 的修复原则一致：资格类字段只降权不淘汰 |
| B5 | 赛事 `eligible_entry_years` 为空 | 放行，并在 DTO 标注 `grade_scope=unknown` | 263/310 属此情况，见 §0.1 D4 |
| B6 | `eligible_entry_years` 非空且用户年级**不在其中** | **淘汰**（唯一保留的资格硬门） | 唯一有明确排他语义的字段，且实测「研究生」类赛事标注完整 |
| B7 | 用户设置了 `major_cluster_override` | **完全以 override 为准**，忽略字典推断；`matched_majors` 照常返回 | 用户显式意图优先于系统推断 |
| B8 | 用户偏好**未配置**（无 `user_competition_preferences` 记录） | P/G/T 三项计 0，不报错、不空返回；M 与 V 照常 | 偏好是可选增强，不是前置条件（与画像就绪不同） |
| B9 | 两项 `match_score` **完全相同** | 按 §4.2 的后续排序键逐级比较；全部相同则按 `id` 升序 | 保证全序，杜绝不稳定排序 |
| B10 | 赛事同时命中专业簇**与**学院 | 只算 `major_match`（更强者），不重复出现 | 一条赛事在响应中只出现一次 |
| B11 | 赛事 `personalized_ranking_allowed=false`（35 条候选池外 + 试点包外） | **可进入结果、可分组，但排序时 M/P/G/T 归零**，等效按 `catalog_order` 排 | 严格遵守 §0.1 D1；未授权赛事顺序不受画像影响 |
| B12 | 赛事 `status != published` 或 `candidate_pool_allowed=false` | 查询阶段即排除，不进入打分 | 治理门，先于一切 |
| B13 | 用户专业名含别名/后缀（如「计算机科学与技术(嵌入式)」） | 先过别名表归一到 canonical，再查映射 | 见 §0.1 D2 |
| B14 | `eligible_majors` 含无法识别的自由文本标签 | 不参与交集，**计入覆盖率报告的未知标签清单** | 与 B1 同理：噪声必须可见 |
| B15 | 同一赛事在目录中存在父子关系（`parent_competition_id`） | 各自独立参与匹配，不做去重；父子去重属产品决策，本期不做 | 避免引入未评审的语义 |

**确定性附加要求**

- 禁止在打分链路引入随机数、`time.Now()` 漂移、非稳定 map 迭代顺序。
  现有 `competitionCandidateLess` 的 `CatalogOrder → CompetitionID → ID` 三级比较是
  确定性的正确做法，应作为最终兜底键保留。
- `score_breakdown` 必须是**可复算**的：给定同一画像与同一目录记录，六项分值与总分必须逐字节一致。
- 时间相关惩罚（如「已截止 −8」）依赖当前时间，因此**黄金用例必须注入固定时钟**。
  仓库已有此模式可循：`NewCompetitionCandidateEngineWithClock`（`competition_candidate_engine.go:45-53`）。

---

## 4. 推荐算法方案

### 4.1 处理管线

```
1. 读取画像（competitioncontext.Builder）
   ├─ 未就绪 → 返回 reason_code=profile_incomplete + 缺失字段清单（不再静默空返回）
   └─ 就绪 → 解析专业簇（含用户 override，见 §6.3）
2. 治理门查询（competitionscope.ApplyCandidate）+ 筛选条件（keyword/category/recognition/date_status）
3. 硬门：E1 已过 / E2 年级 / E3 时间
4. 逐条计算：分组（major_match / college_match / general_match）+ match_score + 可解释性字段
5. 组内按 match_score 排序 → 组间按固定顺序拼接 → 赋 rule_order
6. 分页，同时返回 has_more（修正 P2-9）
```

### 4.2 排序与确定性

排序键（严格有序，保证同输入同输出）：

```
match_score DESC
  → competition_rating 序（S>A>B+>B>B->C）
  → importance_score DESC
  → catalog_order ASC
  → competition_id ASC
  → id ASC（最终稳定 tie-break）
```

确定性是硬要求（runbook 要求可复现、可审计、可回滚），因此：
- 禁止在打分链路引入随机数、时间漂移或非稳定 map 迭代；
- 必须提供黄金用例快照测试：固定画像 + 固定目录 → 断言完整顺序字节级一致。

### 4.3 数据来源清单

| 数据 | 来源 | 现状 | 需补 |
|---|---|---|---|
| 用户专业/学院/年级 | `users.edu_major` / `edu_college` / `edu_grade` | 已有 | — |
| 身份核验 | `models.HasVerifiedAcademicIdentity` | 已有 | — |
| 学校专业字典 | **新建** `academic_majors` | 无 | 初始化来源：`AdminCompetitionAudienceOptions`（`competition.go:681`）已按已核验用户去重导出 college/major，可作冷启动；正式清单由教务提供（D2） |
| 专业 → 簇映射 | **新建** `academic_majors.cluster_tags` | 无 | 自动推导 + 人工复核 |
| 赛事专业范围 | `competition_events.eligible_majors` | 259/310 非空 | **无需归一化**（已是簇口径）；仅画像侧需 `标准专业名 → 簇` 映射，见 §6.2 |
| 赛事方向标签 | `competition_events.tags`（22 词表） | 有，未用 | 接入桥接层 |
| 赛事类别 | `competition_categories.slug`（10 类） | 有，未用 | 接入桥接层 |
| 赛事价值 | `competition_rating` / `importance_score` / `school_recognition_status` | 有 | — |
| 投入估计 | `participation_type` / `team_size_min,max` / 时间字段 | 有 | 复用 `estimatedCompetitionWeeklyHours` |
| 用户偏好 | `user_competition_preferences` | 有 | 标签枚举服务端校验 |
| 用户能力 | `user_competition_awards.skill_tags` / `role` | 有 | 用于解释与二次校准 |

### 4.4 性能

- 规模量级 310 条已发布赛事，全量载入内存打分完全可接受；**不要**为了「算法感」引入向量检索或外部模型。
- 后续若目录增长到数千条，再考虑把「专业簇交集」下推到 DB 侧预过滤（`eligible_majors` 的 JSON 包含查询 + 索引）。当前量级在内存中做集合交集即可。
- 硬性带宽：候选接口 P95 ≤ 600ms（当前量级）；诊断计数随响应返回（阶段 0）。

### 4.5 算法版本与回滚

- 通过 `algorithm_version` 字段与埋点绑定，便于按版本评估。
- 保留总开关：关闭即回退到目录序（`catalog_order`），不影响召回分组 —— 保证「出问题能立刻降级」。

---

## 5. 前端展示与交互改动

> 约束：`AGENTS.md` 规定 `client/` 下的 UI/设计/交互/动效改动必须先读并遵循
> `skills/sylulive-design-engineering/SKILL.md`，并以 `docs/design/DESIGN_SYSTEM.md`、
> `MOTION.md`、`ACCESSIBILITY.md`、`DESIGN_QA.md` 为契约；不得静默覆盖 `docs/design/adr/`。

| 编号 | 文件 | 改动 |
|---|---|---|
| F1 | `screens/competition/competition_center_screen.dart:295-297` | 删除静默回退。画像未就绪时保持「适合我」选中，展示明确未就绪卡片 + 「去完善教务身份」按钮（跳 `competition_my_hub_screen`），返回后自动重试 |
| F2 | 同上 `:327-335` | 对 404 / 503 做显式降级：提示「匹配服务暂不可用」并提供「切到全部」按钮，禁止静默空列表 |
| F3 | 同上 `_buildCandidateNotice` `:893-940` | 拆成三态：未就绪 / 已就绪有结果（显示「根据计算机类专业方向筛出 N 项」）/ 已就绪 0 结果（显示「未找到匹配，试试放宽偏好」+ 直达偏好页） |
| F4 | 同上 `:389` + 后端 | 停止客户端推断 `_hasMore`，改用服务端 `has_more` 字段（修正 P2-9） |
| F5 | `widgets/competition/competition_student_event_card.dart` | 新增匹配度徽标 + 命中依据短文案（例：`计算机类 · 专业直接相关`）；徽标**不得仅靠颜色区分**，需带文字/图标（ACCESSIBILITY） |
| F6 | `widgets/competition/competition_match_reason_sheet.dart` | ① 补齐 6 个恒为「尚未确认」的维度（依赖后端补算）；② 新增「匹配明细」区块渲染 `score_breakdown`；③ 把「匹配度」与「赛事价值（人工评级）」明确分区，并保留现有免责声明 |
| F7 | `screens/competition/competition_preference_screen.dart` | 方向/技能 chips 与后端受控枚举对齐（去掉「后端不校验」的现状）；新增「系统推断的专业方向（可修改）」区块，落地用户纠错 |
| F8 | `screens/competition/competition_my_hub_screen.dart:317-330` | 「匹配候选 N 项」口径与「适合我」一致；0 项时给引导而非仅显示 0 |
| F9 | `widgets/competition/competition_ui_tokens.dart` | 新增匹配度徽标的语义色 token（沿用既有 token 体系，避免硬编码色值；不得触碰 ADR-001 品牌色语义） |
| F10 | 全局 | 埋点：`fit_tab_exposure`、`candidate_impression`、`match_reason_open`、`candidate_click`、`calendar_add`，字段含 `algorithm_version` / `match_score` / `match_tier` / `match_basis` / `position` |
| F11 | `config/beta_release_policy.dart:10` | `competitionCandidateMatching` 已为 true，保持；阶段 2 的排序能力如需灰度，另开独立开关，不复用该常量 |

---

## 6. 后端数据结构调整

### 6.1 新表

**`academic_majors`（学校专业字典 + 簇映射）**

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | uint PK | |
| `name` | varchar(100) | 教务口径标准专业名 |
| `normalized_name` | varchar(100) uniqueIndex | 归一化后名称 |
| `college_name` | varchar(100) index | 所属学院 |
| `discipline_code` | varchar(20) | 国标专业代码（可选） |
| `cluster_tags` | json | 映射到的专业簇数组 |
| `source` | varchar(20) | `roster` / `user_derived` / `manual` |
| `is_active` | bool index | |
| `verified_by` / `verified_at` | uint / time | 人工复核留痕 |

**`competition_direction_clusters`（可选，二级桥接）**

`direction_tag`（对齐客户端 `competitionDirectionOptions` 11 项）、`cluster`、`weight`。
若 `primary_category.slug` 与簇的映射足够覆盖，可省略本表。

### 6.2 `competition_events`：**本期不加任何列**

按 §0.1 D1 的结论（复用既有治理字段）与本节的收敛，原计划中的三个新列**全部取消**：

| 原计划字段 | 取消原因 |
|---|---|
| `major_ranking_allowed` | 复用 `personalized_ranking_allowed`；新开字段会破坏全部 `record_hash`（见 §0.1 D1） |
| `major_fit_clusters` | **不需要**。赛事侧 `eligible_majors` 本身就已是「专业簇词表」口径，只有**画像侧**需要做 `标准专业名 → 簇` 的归一化。赛事侧再存一份派生列会引入与源字段的漂移，且无收益 |
| `major_fit_source` | 数据可信度应由 D3 的离线复核流程给出，不需要以目录字段形式落库（落了就要进 hash） |

本期对 `competition_events` 的改动**只有值，没有结构**：

- `personalized_ranking_allowed`：把 `candidate_pool_allowed=true` 的 **275 条**翻转为 `true`
  （其余 35 条保持 `false`）；`strong_recommendation_eligible` 全部保持 `false`。
- 翻转通过目录包完成（exporter → 重算 `record_hash` / `package_hash` → validate → import → diff → activate），
  **禁止直接改库**。分「信息科学与工程学院试点包（109 条）」与「全量包」两次发布。

> 匹配运算因此变成纯粹的**集合交集**：`用户专业簇 ∩ event.eligible_majors`。
> 这是刻意保留的简化 —— 旧实现在 `competitionSearchableText` 上做全字段子串匹配
> （`competition_preference_matching.go:127-148`）正是噪声的来源，不应重新引入模糊文本匹配。


### 6.3 `user_competition_preferences` 增改

- `direction_tags` / `skill_tags`：增加服务端受控枚举校验（当前仅校验长度与数量，
  `handlers/competition_preference.go:166-194`），与客户端 11 + 12 词表对齐。
- `major_cluster_override` **新增** json：允许用户手动修正系统推断的专业簇。
  这是映射漏配时的关键降级路径，也是阶段 3 纠错闭环的入口。

### 6.4 治理与快照契约

- `handlers/competition_recommendation_snapshot.go:103` 的 `event.PersonalizedScore = nil` 需调整为
  条件写入：仅当 `personalized_ranking_allowed` 为真且 `algorithm_version ≥ major-match-v1` 时，
  写入新字段 `match_score` / `match_tier` / `match_basis` / `score_breakdown`。
  **不复用 `personalized_score` / `recommendation_tier`**：前者被 runbook 明令禁止出现在候选响应中，
  后者被旧客户端兼容占用且在治理语境指「推荐等级」，混用即治理语义污染。
- 同步更新 `handlers/competition_candidate_test.go:114` 的禁用字段断言与新字段命名；
  兼容层 `legacyCandidateMap`（`competition_candidate.go:140-151`）需继续剥离全部打分字段。
- **必须新增 ADR**（`docs/design/adr/`），记录：`personalized_ranking_allowed` 自本次起同时承载
  「含专业维度的确定性排序」这一窄语义，该能力**不含** AI 解释、不含强推荐、不含获奖预测；
  并修订 `docs/competition-catalog-v2-runbook.md:9` 与 `:141` 两处表述
  （「目录禁止排名时顺序不受画像影响」→「允许排名时顺序必须可复现、可审计、可回滚」）。
- MCP 通道（`handlers/internal_mcp_competition.go`、`internal/ai/hy3_decision_tools.go` 的
  `explain_competition_candidates`）复用同一候选引擎，契约变更需同步，避免解释端与展示端不一致。

### 6.5 索引

- `academic_majors(normalized_name)` unique（唯一必要的新索引）
- 无需为 `competition_events` 新增索引：`personalized_ranking_allowed` 只作读时判定，不作为查询过滤条件

### 6.6 迁移与回填

1. 建表 `academic_majors`（DB-only，不进目录包、不影响任何 hash）。
2. 专业字典初始化：先由 `AdminCompetitionAudienceOptions` 已核验用户画像去重冷启动
   （`source=user_derived`），再由教务名册覆盖（`source=roster`）。
3. 13 学院 × 53 簇映射矩阵由各学院教务员填写并复核（`source=manual`）。
4. 数据复核：跑一致性审计（专业簇 × 学院是否自洽、哪些专业无映射），产出问题清单；
   目录侧的三类修复（§0.1 D3）**与 D1 的字段翻转合并成同一次目录重导出**，
   **复用**现有 admin catalog 的 validate → import → diff → activate 流程，禁止直接改库。


---

## 7. 分阶段实施步骤与验收标准

### 阶段 0：止血与可观测（当天～次日）

**改动**
1. 确认并固化 `COMPETITION_CANDIDATE_ENGINE_V2_ENABLED=true`（部署配置 + 文档），消除 P1-5 的 404 隐患。
2. 候选接口增加管线诊断：返回各环节计数（总库 → 治理门 → 年级门 → 专业门 → 分组 → 分页），
   便于线上定位「0 结果」。
3. 前端 F1 + F2：消除静默回退与静默空列表。
4. 不动算法、不动数据结构。

**验收**
- 任一已核验身份用户点「适合我」不再出现「毫无反应」；未就绪有明确引导。
- 开关开启的环境候选接口返回 200；诊断计数可见且与实测一致（310 → 275 → …）。
- 候选接口 P95 ≤ 600ms。
- **记录测试基线**：`go test ./internal/handlers/ -run 'Competition'` 为 `ok`
  （本地实测 108.7s）；同时记录全量套件的既存失败数（19 个），作为本次改造的对照基准，
  **不作为本次验收项**（见 D10 / §10.1）。

### 阶段 1：召回修复（核心，1–2 周）

**改动**
1. 建 `academic_majors` + 簇映射，覆盖学校实际专业；以**附录 B 草案表**为起点交付学院核对，
   产出覆盖率报告与待复核清单（含附录 B.1 的 8 处词表缺口）。
2. 引擎改造（`services/competition_candidate_engine.go`）：
   - `buildCompetitionCandidate` 改用专业簇交集，替换 `containsCandidateValue` 的全等判定；
   - 专业不命中由 `return false` 改为降级到 `general_match`（**P0-2**）；
   - 分组语义修正为「专业簇命中 / 学院命中 / 通用」；
   - 实现 §3.6 的 B1–B15 边界契约（**每一条都要有对应测试**）；
   - 补齐 6 个恒为 `unknown` 的匹配维度（`Goal/Direction/Skill/Role/Time/Training`）。
3. 修复目录数据错配（如化学实验创新设计大赛）；**本期不改标签口径**，模糊标签只登记不重命名。
4. 前端 F3/F5/F6（补算后的维度与命中依据）；后端补 `has_more` / `reason_code`（F4）。

**验收（对照 §1.3 基线，硬指标）**

> 以下指标已按实测结果修正，详见 `competition-recommendation-algorithm-plan.md` §11。
> 原「四类专业召回量差异 ≤ 30%」被实测证伪（实测 2.84），已替换为「召回下限 ≥ 20」；
> 原因是目录供给本身不平衡（计算机类 81 条 vs 英语 29 条），而非算法缺陷。

- 计算机科学与技术 `major_match` 0 → **71**（实测，目标 ≥ 60）；自动化 0 → **31**；
  机械设计制造及其自动化 0 → **44**。
- **每个专业的专业相关召回 ≥ 20**（替代原均衡度指标）。
- 被丢弃数从 219–279 降至 **47**，且全部为年级门真实不符（实测）。
- 「有专业标注反被淘汰」的悖论消除：`major_match` 计数与 `eligible_majors` 非空数呈正相关。
- 解释弹窗中「尚未确认」维度从 6/10 降至 **≤ 3/10**（`Goal/Direction/Skill/Role/Time/Training`
  六项已由打分器实际计算）。
- 目录侧未识别标签为 **0**（实测，53 个标签全部可解析）。
- 确定性：263 条候选重复计算顺序 100% 一致（实测）。
- **注意**：上述为离线复算结果。首屏可见改善**依赖阶段 2 的目录授权翻转**——
  实测在 0/310 授权状态下首屏专业相关占比仅 0–3/10，授权模拟态为 9/10。
  阶段 1 上线应预期「分组正确、首屏未变」，不得据此误判算法失败。
- **竞赛相关测试子集全绿**：`competition_candidate_engine_test.go`、`competition_candidate_test.go`、
  `competition_preference_matching_test.go`，加新增的 `internal/competitionmatching` 22 个用例，
  加 B1–B15 边界用例；前端 `competition_center_screen_test.dart`、
  `competition_student_event_card_test.dart` 全绿。
  （**口径限定见 D10 / §10.1：不含 19 个无关既存失败。**）
- 覆盖率审计报告（§10.3）产出：无映射专业清单、未识别标签清单均**为空或已逐项登记**。


### 阶段 2：个性化排序上线（1–2 周）

**改动**
1. 写 ADR（§0.1 D1），修订 runbook 两处表述。
2. 出「试点目录包」：只翻转信息科学与工程学院相关 **109 条** 的 `personalized_ranking_allowed`，
   走 validate → import → diff → activate；与 D3 的三类数据修复合并进同一次重导出。
3. 落地 §3.4 打分与 §4.2 排序；**先 shadow 运行**（同时算分但不改序）1 周。
4. 治理与快照契约调整（§6.4）；同步 MCP 解释通道。
5. 前端 F6/F7/F9/F10。
6. 试点验收通过后再出全量包（275 条）。

**验收**
- Top10 中 `major_match` 占比 ≥ **70%**（shadow 阶段连续 3 天，见 §9.2）。
- `zero_result_rate < 5%`、`p95_latency ≤ 600ms`、`top20_overlap` 处于合理区间（§9.1）。
- 黄金用例快照测试：同输入 100% 确定性（顺序字节级一致），且**注入固定时钟**。
- **回滚演练覆盖两级**（§9.3）：① 关总开关秒级恢复 `catalog_order`；② 目录包 rollback 恢复上一包。
- **竞赛相关测试子集**全绿：治理断言（`blocked`/`catalog_only` 不出现；
  未授权赛事顺序不受画像影响；`match_score` 不与 `competition_rating` 混用）+
  legacy `/fit` 兼容层不泄漏任何打分字段 + B1–B15 边界用例。
  （**口径限定见 D10 / §10.1。**）
- 目录侧校验全绿：试点包 `record_hash` / `package_hash` 复算一致，
  `strong_recommendation_eligible` 仍全 false，35 条候选池外赛事的 `personalized_ranking_allowed` 仍为 false。
- runbook 两处表述已修订，且本计划与 ADR 互链。

### 阶段 3：闭环与调优（持续）

**改动**
1. 埋点落地 → 离线评估（NDCG@10、专业命中率、点击率、加入计划转化）。
2. 权重与阈值调参（保留 `algorithm_version` 便于对比）。
3. 用户纠错闭环（`major_cluster_override`）+ 管理端簇覆盖看板与批量复核。

**验收**
- 「适合我」点击率相对基线提升 ≥ **15%**。
- 0 结果率 < **5%**。
- 用户专业簇纠正率 < **10%**（说明映射质量达标）。
- 活跃用户「适合我」使用率 ≥ **40%**。

---

## 8. 风险、依赖与待决策项

结论均已给出，详见 §0.1。下表保留决策状态与残余风险。

| 编号 | 事项 | 状态 | 结论 / 建议 |
|---|---|---|---|
| D1 | 个性化排序与目录治理冲突 | **已给结论** | 不新开字段，复用 `personalized_ranking_allowed`；翻转 275 条候选池内赛事；`strong_recommendation_eligible` 保持 false；走目录包发布，禁止改库；分试点（109 条）与全量两包；补 ADR |
| D2 | 教务标准专业名清单来源 | **已给结论** | 教务名册为权威（一次性 Excel 即可）；`AdminCompetitionAudienceOptions` 冷启动；13 学院 × 53 簇映射矩阵由学院教务员填写；必须配别名表与覆盖缺口报告 |
| D3 | 目录 53 个标签可否修订 | **已给结论** | 本期不动标签口径（画像侧单向归一化）；只修三类必须修的（错配 / 年级字段 / 15 个模糊标签），且与 D1 合并成一次目录重导出 |
| D4 | 年级数据仅 47/310 | **风险下调** | 实测「研究生」赛事全部有 `eligible_entry_years`，年级门对其生效；缺口是覆盖面而非正确性。接受「不限年级即放行」并标注 |
| D5 | 专业标签错配（如化学实验创新设计大赛） | 待分配责任人 | 走 admin catalog diff 流程修复，与 D3 同批次 |
| D6 | 「适合我」是否过滤已截止/已加入计划赛事 | 待产品确认 | 建议：已截止默认过滤；已加入计划的置底并标注「已加入计划」 |
| D7 | 画像核验覆盖率未知 | 待统计 | 阶段 0 一并统计 `profile_ready` 覆盖率，作为功能价值基线 |
| D8 | 目录重导出的责任人与备份门禁 | 待确认 | 按 runbook「数据库备份门禁」执行：备份 → 校验非空可读 → 记录路径与 SHA-256 → 再导入激活 |
| D9 | 排期外的组织依赖 | 待确认 | ① ADR 评审人；② 学院教务员填映射矩阵的对接人；③ 数据复核责任人。三者是唯一的外部依赖，缺任一项阶段 2 无法启动（详见 §12） |
| **D10** | **`internal/handlers` 套件当前不全绿** | **验收口径已调整** | 基线实测：竞赛子集 `go test ./internal/handlers/ -run 'Competition'` → `ok`；全量 → FAIL，19 个**与竞赛无关**的既存失败（清单见 §10.1）。本计划所有「测试全绿」均限定为**竞赛相关子集**。这 19 个失败是独立的历史欠债，建议单独立项，**不要**混入本次改造 |
| D11 | 目录簇词表存在 8 处口径缺口 | 阶段 1 交付物 | 见附录 B.1；随 D3 的目录修复一并关闭，需教务员核对确认 |


---

## 9. 权重校准、灰度判据与回滚阈值

阶段 2 的「先 shadow 运行」不能只写一句口号，必须给出可判定的进出条件。

### 9.1 Shadow 阶段的对比指标

并行计算两条排序（新算法 vs 现行 `catalog_order`，**输出仍用旧序**），按天产出：

| 指标 | 定义 | 用途 |
|---|---|---|
| `major_hit_top10` | Top10 中 `match_basis=major_cluster` 的占比 | 主指标，目标 ≥ 70% |
| `top20_overlap` | 新旧 Top20 重合条目数 | 观察改序幅度是否失控；过低说明权重失衡 |
| `zero_result_rate` | `total == 0` 的请求占比 | 目标 < 5% |
| `cluster_unmapped_rate` | 带 `reason_code=cluster_unmapped` 的占比 | 直接暴露映射缺口（B1） |
| `unknown_label_rate` | `eligible_majors` 未识别标签占比 | 直接暴露目录噪声（B14） |
| `p95_latency` | 候选接口 P95 | ≤ 600ms |

### 9.2 全量开启的准入条件（三条同时满足）

1. `major_hit_top10 ≥ 70%` 连续 3 天；
2. `zero_result_rate < 5%` 且 `p95_latency ≤ 600ms`；
3. 试点的 109 条赛事中，无一条 `personalized_ranking_allowed=false` 的赛事出现非目录序。

### 9.3 回滚阈值（任一触发即回滚）

| 触发条件 | 动作 |
|---|---|
| `zero_result_rate > 15%` | 立即关总开关，回目录序 |
| `p95_latency > 1200ms` | 立即关总开关 |
| 用户反馈/客诉出现「推荐不相关」且 24h 内 ≥ 3 例 | 关总开关并冻结灰度扩大 |
| 任一治理断言被破坏（如 `blocked` 赛事出现在结果里） | 立即关总开关 + 走事故流程 |

**回滚手段有两级**，演练必须覆盖两级：

1. **功能开关**：关闭排序，立即恢复 `catalog_order`（秒级，不动数据）；
2. **目录包回滚**：`POST /api/admin/competition-catalog/packages/:current_id/rollback`
   恢复上一包（分钟级，连字段翻转一起回退）。

---

## 10. 测试计划与回归清单

### 10.1 现状与前提（必须先明确）

本仓库 `internal/handlers` 测试套件**当前不是全绿的**。基线实测：

- `go test ./internal/handlers/ -run 'Competition'` → **`ok`（108.7s）**，竞赛相关用例全通过；
- `go test ./internal/handlers/`（全量）→ **FAIL**，19 个**与竞赛无关**的既存失败：
  `TestAcademicConfigRevisionIsolationAndReplay`、`TestAICapabilitiesReturnsUnlimitedQuotaForVerifiedStudent`、
  `TestAIEventsDisconnectKeepsRunAlive`、`TestCancelRunEndpointCancelsRun`、
  `TestGetSourceChunkOnlyReturnsPublishedKnowledge`、`TestGetRunSourcesOnlyReturnsOwnedPersistedSources`、
  `TestDeleteConversationRetainsConsumedQuotaLedger`、`TestListConversationsWithPreview`、
  `TestAIEventsReplaysPersistedEventsAfterLastEventID`、`TestAppealDetailEnforcesAccessAndUsesPrivacyDTO`、
  `TestAdminResolveReviewRejectsOriginalHandler`、`TestReviewRequiredNotifiesIndependentReviewer`、
  `TestVoteRejectsAfterDeadline`、`TestEmojiFavoriteHandlerListIsUserScoped`、
  `TestEmojiFavoriteHandlerQuotaErrorIncludesUsageFields`、`TestEmojiFavoriteHandlerServeAssetIsOwnerScoped`、
  `TestFeedbackSubmitRejectsOversizedAttachment`、`TestInternalMCPV5AcademicSummaryUsesGrantSubjectNotRequestBody`、
  `TestInternalMCPV5GrantCannotCallAnotherCapability`。

**因此本计划的验收标准统一改为「竞赛相关测试子集全绿」，而不是「仓库测试全绿」。**
（这一条已经写进 §7 各阶段验收，避免把无关历史欠债算到本次头上。）

### 10.2 必须覆盖的测试类型

| 类型 | 内容 | 归属 |
|---|---|---|
| 单元测试 | 专业簇交集、硬门→降级、六项打分、B1–B15 全部边界各一例 | 阶段 1 |
| 黄金用例快照 | 固定画像 + 固定目录 + 固定时钟 → 断言完整顺序与 `score_breakdown` 字节级一致 | 阶段 1 建立，阶段 2 强制 |
| Fixture 矩阵 | 4 类专业（计算机类/机械类/艺术类/经管类）× 3 个真实专业名，断言各组召回下限 | 阶段 1 |
| 回归清单 | 现有 `competition_candidate_engine_test.go`、`competition_candidate_test.go`、`competition_preference_matching_test.go` 全绿 | 每阶段 |
| 治理断言 | `blocked`/`catalog_only` 不出现；未授权赛事顺序不受画像影响；`match_score` 不与 `competition_rating` 混用 | 阶段 2 |
| 前端测试 | 现有 `competition_center_screen_test.dart`、`competition_student_event_card_test.dart` 全绿 + 新增三态图标/徽标用例 | 阶段 1–2 |

### 10.3 数据侧验收脚本（离线，不依赖线上）

沿用 `tools/competition_catalog/` 的离线校验习惯，新增一个「覆盖率审计」脚本，
输入目录 JSON + 映射表，输出：

- 每个簇被多少赛事引用；
- 哪些标准专业无映射（B1）；
- 哪些 `eligible_majors` 标签无法识别（B14）；
- 「-相关」类模糊标签的引用分布（对应 §0.1 D3）。

这份报告是阶段 1 验收的**直接证据**，也是交给教务员填映射表的输入。

---

## 11. 接口与兼容性影响

| 受影响面 | 影响 | 处置 |
|---|---|---|
| 新增 DTO 字段（`match_score` 等） | 旧客户端不认识新字段，会被忽略 —— 安全 | 保持纯新增，不改既有字段类型与语义 |
| `/user/competitions/candidates` 新增 `has_more` / `reason_code` | 纯新增 | 旧客户端继续用 `total`/`page` 推断，不报错 |
| `/competitions/fit` 兼容层 | 必须继续剥离全部打分字段 | 更新 `competition_candidate.go:140-151` 的 `delete` 列表；同步更新 `competition_candidate_test.go:114` 的禁用字段断言 |
| MCP 解释通道 | `explain_competition_candidates` 与展示端共用引擎，顺序变化会影响 AI 解释的参照顺序 | 契约同步 + 快照校验（§6.4） |
| 客户端 `BetaReleasePolicy` | `competitionCandidateMatching` 已为 true，不改 | 阶段 2 的排序灰度另开开关 |

---

## 12. 排期、人力与外部依赖

| 阶段 | 预估 | 人力假设 | 关键产出 |
|---|---|---|---|
| 阶段 0 | 1–2 人日 | 1 后端 + 1 前端（可并行） | 开关固化、诊断计数、前端消除静默回退 |
| 阶段 1 | 5–8 人日 | 1 后端 + 1 前端 + 0.5 数据 | 映射表落地、引擎改造、fixture 验收报告 |
| 阶段 2 | 5–8 人日 + 1 周观察期 | 1 后端 + 1 前端 + 1 治理/评审 | ADR、试点目录包、shadow 报告、全量包 |
| 阶段 3 | 持续 | 0.5 后端 + 0.5 数据 | 埋点看板、纠错闭环 |

**外部依赖（阻塞项，缺一不可）**

| 编号 | 依赖 | 阻塞对象 | 建议动作 |
|---|---|---|---|
| E1 | ADR 评审人 | 阶段 2 全部 | 现在指定，可在阶段 1 期间并行评审 |
| E2 | 学院映射表填写对接人（13 个学院） | 阶段 1 的映射质量 | 阶段 0 期间就发出草案表（附录 B）请其核对 |
| E3 | 目录数据复核责任人 | §0.1 D3 的三类修复 | 与 E2 同一批人即可 |
| E4 | 数据库备份门禁执行人 | 阶段 2 目录激活 | 按 runbook「数据库备份门禁」流程预先演练一次 |

**三个并行优化点**（不增加外界依赖，可提前做）

- E2 的草案表（附录 B）由我方先出，教务员只做「核对 + 改错」，而不是从零填 —— 这是压缩阶段 1 周期的关键；
- 覆盖率审计脚本（§10.3）可在阶段 0 就写，阶段 1 直接用；
- 黄金用例 fixture 可在阶段 0 就设计好输入格式，阶段 1 直接填断言。

---

## 附录 A：关键文件索引

| 用途 | 路径 |
|---|---|
| 候选引擎（核心改造对象） | `server/internal/services/competition_candidate_engine.go` |
| 用户画像构建 | `server/internal/competitioncontext/context.go` |
| 目录范围与治理门 | `server/internal/competitionscope/scope.go` |
| **目录记录哈希（D1 结论依据）** | `server/internal/services/competition_catalog_hasher.go:16-36` |
| **目录校验与治理约束网（D1 结论依据）** | `server/internal/services/competition_catalog_validator.go:104-127` |
| 目录记录结构（含治理字段） | `server/internal/dto/competition_catalog.go:19-76` |
| 死代码偏好打分（迁移来源） | `server/internal/handlers/competition_preference_matching.go` |
| 候选 / 兼容接口 | `server/internal/handlers/competition_candidate.go` |
| 偏好读写与校验 | `server/internal/handlers/competition_preference.go` |
| AI 推荐快照契约 | `server/internal/handlers/competition_recommendation_snapshot.go` |
| 路由与开关 | `server/cmd/main.go:1519-1529`、`server/internal/config/config.go:488` |
| 固定时钟构造（黄金用例前置） | `server/internal/services/competition_candidate_engine.go:45-53` |
| 竞赛中心页 | `client/lib/screens/competition/competition_center_screen.dart` |
| 赛事卡片 | `client/lib/widgets/competition/competition_student_event_card.dart` |
| 匹配说明弹窗 | `client/lib/widgets/competition/competition_match_reason_sheet.dart` |
| 偏好设置页 | `client/lib/screens/competition/competition_preference_screen.dart` |
| 受控词表 | `client/lib/models/competition_preference.dart:61-88` |
| 治理手册（需修订） | `docs/competition-catalog-v2-runbook.md:9,141` |
| 覆盖率审计脚本（新增） | `tools/competition_catalog/`（沿用既有离线校验习惯，见 §10.3） |
| 设计契约（前端改动前置） | `skills/sylulive-design-engineering/SKILL.md`、`docs/design/*` |

---

## 附录 B：草拟「标准专业 → 专业簇」映射表

> **性质说明**：本表是**按目录实测的 53 个簇标签反推的草案**，用于给学院教务员核对修改（§12 E2）。
> 标准专业名一栏以**教务名册为准**，本表所列专业名可能缺失或命名不符，请以核对结果覆盖。
> 标注「⚠ 词表缺口」的项说明现有 53 个簇里**没有对应口径**，需在 §0.1 D3 的目录修复中补充或明确降级。

| 学院 | 标准专业（待教务核对） | 映射到的簇 |
|---|---|---|
| 信息科学与工程学院 | 计算机科学与技术 | 计算机类 |
| | 软件工程 | 计算机类、软件工程 |
| | 网络工程 | 计算机类、网络工程 |
| | 物联网工程 | 计算机类、网络工程 |
| | 数据科学与大数据技术 | 数据科学类、计算机类 |
| | 人工智能 | 智能科学类、数据科学类、计算机类 |
| | 智能科学与技术 | 智能科学类、计算机类 |
| | 电子信息工程 | 电子信息类 |
| | 通信工程 | 通信工程、电子信息类 |
| | 电子科学与技术 | 电子信息类、微电子相关 |
| | 集成电路设计与集成系统 | 集成电路相关、电子信息类 |
| 自动化与电气工程学院 | 自动化 | 自动化类、自动化相关 |
| | 电气工程及其自动化 | 电气工程类、自动化类 |
| | 机器人工程 | 机器人工程、自动化类 |
| | 测控技术与仪器 | 自动化类 ⚠ 词表缺口（无仪器仪表类） |
| | 探测制导与控制技术 | 自动化类、电子信息类 |
| 机械工程学院 | 机械设计制造及其自动化 | 机械类、工程设计相关 |
| | 机械电子工程 | 机械类、自动化类 |
| | 材料成型及控制工程 | 材料类、材料成型及控制工程、机械类 |
| | 工业设计 | 工业设计、工程设计相关、产品设计 |
| | 过程装备与控制工程 | 机械类 ⚠ 词表缺口（无过程装备口径） |
| | 焊接技术与工程 | 材料类、机械类 |
| 装备工程学院 | 武器系统与工程 | 机械类、工科相关专业 ⚠ 词表缺口（无兵器类） |
| | 弹药工程与爆炸技术 | 机械类、工科相关专业 ⚠ 词表缺口 |
| 汽车与交通学院 | 车辆工程 | 车辆工程、机械类 |
| | 汽车服务工程 | 车辆工程、机械类 |
| | 装甲车辆工程 | 车辆工程、机械类 |
| | 交通运输 | 交通运输相关、工科相关专业 |
| | 物流管理 | 物流管理相关、管理科学与工程类 |
| 材料科学与工程学院 | 材料科学与工程 | 材料类 |
| | 金属材料工程 | 材料类、金属材料工程相关 |
| | 无机非金属材料工程 | 材料类 |
| | 高分子材料与工程 | 材料类 |
| | 复合材料与工程 | 材料类 |
| 环境与化学工程学院 | 化学工程与工艺 | 化学工程与工艺、化学相关 |
| | 应用化学 | 应用化学、化学相关 |
| | 环境工程 | 环境工程 |
| | 安全工程 | 环境工程、工科相关专业 ⚠ 词表缺口（无安全类） |
| | 制药工程 | 化学工程与工艺、生命健康相关 |
| 理学院 | 数学与应用数学 | 数学与应用数学、数学类 |
| | 信息与计算科学 | 数学类、数据科学类 |
| | 应用统计学 | 统计学类、数学类 |
| | 应用物理学 | 工科相关专业 ⚠ 词表缺口（无物理类） |
| | 光电信息科学与工程 | 电子信息类、工科相关专业 ⚠ 词表缺口 |
| 经济管理学院 | 工商管理 | 工商管理类、工商管理 |
| | 市场营销 | 市场营销、工商管理类 |
| | 会计学 | 会计学、工商管理类 |
| | 财务管理 | 财务管理、会计学 |
| | 金融学 | 金融学、经济学类 |
| | 经济学 | 经济学类、经济学相关 |
| | 国际经济与贸易 | 国际经济与贸易、经济学类 |
| | 电子商务 | 电子商务、工商管理类 |
| | 信息管理与信息系统 | 管理科学与工程类、计算机类 |
| 艺术设计学院 | 视觉传达设计 | 视觉传达设计、数字媒体相关 |
| | 环境设计 | 环境设计 |
| | 产品设计 | 产品设计、工业设计 |
| | 动画 | 动画、数字媒体相关 |
| | 数字媒体艺术 | 数字媒体相关、动画、视觉传达设计 |
| 外国语学院 | 英语 | 英语、翻译 |
| | 俄语 | 俄语、翻译 |
| | 翻译 | 翻译、英语、国际交流相关 |
| 马克思主义学院 | 思想政治教育 | 思想政治教育相关、人文社科相关 |
| 创新创业学院 | （面向全校，无专属专业） | 由 `general_match` 覆盖 |

### 附录 B.1 由此表得出的词表缺口清单（D3 的输入）

填表过程中暴露的**目录侧口径缺失**，共 8 处，必须在 §0.1 D3 的目录修复中一并处理：

| 缺失口径 | 影响专业 | 建议 |
|---|---|---|
| 仪器仪表类 | 测控技术与仪器 | 新增簇，或明确降级到 自动化类 |
| 过程装备类 | 过程装备与控制工程 | 降级到 机械类 |
| 兵器/国防类 | 武器系统与工程、弹药工程与爆炸技术 | 新增簇（目录已有 `defense_security_other` 类别可对齐） |
| 安全类 | 安全工程 | 降级到 环境工程 |
| 物理类 | 应用物理学 | 新增簇 `物理类` |
| 光电类 | 光电信息科学与工程 | 降级到 电子信息类 |
| 数学/统计细粒度 | 信息与计算科学、应用统计学 | 已可由 `数学类`/`统计学类` 覆盖，无需新增 |

> 这张缺口清单本身就是阶段 1 的重要交付物：它把「为什么某些专业永远匹配不到」
> 从一句猜测变成了**可逐项核对、可关闭的清单**。

