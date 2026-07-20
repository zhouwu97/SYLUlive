# 客户端低风险个人 Skill 阶段五总结报告

## 一、实施结论

阶段五已完成。客户端新增了固定允许列表的只读 Skill 层，提供以下六项能力：

| Skill ID | 敏感级别 | 读取范围 | 输出上限 |
| --- | --- | --- | --- |
| `personal.schedule.today` | 低 | 指定自然日课表 | 32 门课程 |
| `personal.schedule.week` | 低 | 最多 7 个自然日课表 | 128 门课程 |
| `personal.academic.overview` | 中 | 成绩覆盖概览 | 24 个学期 |
| `personal.physical.overview` | 中 | 最近学年体测概览 | 20 个项目 |
| `personal.erke.overview` | 中 | 二课概览 | 20 个分类、5 条最近活动 |
| `campus.competition.search` | 公开 | 公开竞赛目录 | 20 条结果 |

本阶段没有接入模型自动调用、权限弹窗、GPA、毕业判断、个性化竞赛排名、
运动计划、自动刷新或任何写操作。Skill 结果也没有发送给校园公共模型或用户
自定义模型。

当前工作分支缺少已在 `origin/main` 合并的阶段四 Gateway 源文件。为保证阶段五
建立在真实只读边界上，本次同时补回了阶段四的账号隔离 Gateway、AES-GCM 快照
存储及二课账号绑定接入；未覆盖工作树中现有的 AI 前端和服务端未提交改动。

## 二、核心实现

### 统一契约

`PersonalSkill<I, O>` 固定暴露 Skill ID、敏感级别、声明的数据类型和执行方法。
`SkillResult<T>` 统一返回：

- `status`：成功、部分成功、缺失、需刷新、输入无效、拒绝、不可用、失败或未知；
- `evidence`：来源、读取范围、数据类型、获取时间、过期时间和过期标志；
- `warnings`：不含个人数值和底层异常正文的可展示提示；
- `containsPersonalData`：明确标识结果是否包含个人数据。

所有集合输出均不可变。缺失、损坏、账号不匹配和上下文关闭时不返回部分个人对象。

### 能力约束

`SkillExecutionContext` 是个人 Gateway 的唯一 Skill 入口。注册表执行前根据
`requiredDataTypes` 创建受限上下文；Skill 尝试读取未声明类型时会在调用 Gateway
前抛出本地边界异常，注册表将结果转换为 `denied`。

`PersonalSkillRegistry` 使用不可变 Map 保存固定 Skill。未知 ID、重复 ID、错误输入
类型、能力集合扩容、未声明数据访问和缺失来源证据都失败关闭，模型字符串不能动态
创建新 Tool 或传入账号标识。派生执行上下文只能收窄现有权限，不能重新扩大权限。

### 最小化输出

- 今日课表只读取一个自然日，返回课程、节次时间、教室和校内日程空闲区间；
- 本周课表最多读取 7 天，拒绝全年或跨月大范围请求；
- 学业概览不包含单门成绩、GPA、学分、学号或毕业结论；
- 体测概览只判断身高与体重原始输入是否齐全，不计算 BMI 或生成医学结论；
- 二课只返回总分、分类摘要和最多 5 条最近活动；
- 公开竞赛只调用 `/competitions/events`，不访问用户竞赛状态或个人 Gateway。

## 三、数据流

```text
内部调用方
  |
  v
PersonalSkillRegistry（固定 ID 校验）
  |
  +-- 公开竞赛 Skill -----------------> 公开竞赛 API
  |
  v
SkillExecutionContext（声明类型裁剪）
  |
  v
PersonalDataGateway（当前账号固定上下文）
  |
  v
AES-GCM Personal Vault
  |
  v
最小化 GatewayOverview
  |
  v
带来源和时间证据的 SkillResult
```

本阶段数据流在 `SkillResult` 处终止，不进入模型请求链路。

## 四、威胁模型与处理

| 风险 | 本阶段处理 |
| --- | --- |
| 未知或伪造 Skill ID | 注册表返回 `unknownSkill`，不执行任何读取 |
| Skill 越权读取 | 受限执行上下文在 Gateway 调用前拒绝 |
| 模型传入学号、用户 ID 或路径 | 所有阶段五输入模型均不包含这些字段 |
| 大范围课表外带 | 本周硬限制 7 天，今日固定 1 天 |
| 结果过大 | 每类输出设置独立条数上限并返回截断警告 |
| 过期缓存伪装实时数据 | 证据保留 `fetchedAt`、`expiresAt` 和 `isStale` |
| 密文损坏或账号切换 | 继承 Gateway 失败关闭语义，不返回旧对象 |
| 公开检索误读个人状态 | 只调用公开赛事目录，参数不含用户标识 |
| 底层异常泄露数据 | 对外仅返回固定错误分类和通用提示 |
| Prompt Injection 扩大允许列表 | 本阶段无模型入口，注册表也不可由文本修改 |

## 五、测试与验收

新增阶段五单元测试覆盖：

- 六个固定 Skill 的注册和独立执行；
- 未知 ID、错误输入类型和未声明数据访问；
- 执行上下文二次收窄时不能扩权，成功结果必须具备来源和时间证据；
- 今日课程时间、教室、空闲区间和证据；
- 本周日期范围上限及超限时零 Gateway 读取；
- 学业缺失状态和部分数据状态；
- 体测 BMI 原始输入可用性；
- 二课最近活动上限；
- 过期数据证据；
- 公开竞赛检索参数、分页限制和零个人 Gateway 读取。

本地验证记录（2026-07-20）：

```text
阶段五定向测试：15 项通过
全量 flutter test --no-pub：608 项通过
全量 flutter analyze --no-fatal-warnings --no-fatal-infos：无 error
阶段五目录定向 analyze：无 warning、无 error
```

全量静态分析仍报告 422 条仓库既有 warning/info，主要为弃用 API、未使用代码和
BuildContext 异步提示；本阶段新增 Skill 目录没有新增静态问题。

## 六、后续边界

阶段六接入模型 Tool Calling 时必须复用本阶段 Registry，不得让模型直接持有
`PersonalDataGateway`。在执行任何个人 Skill 前，还必须增加参数校验、权限预览、
用户确认、账号切换取消、Tool 轮数/超时/结果字符上限以及 Provider 数据路由。

在这些阶段六控制完成前，阶段五 Skill 只能由受信任的本地调用方和测试代码调用。
