# 客户端个人 AI Skill 清单

版本：`skill-schema-v1`

Skill 注册表由客户端固定代码构造，模型、服务端响应和网络内容都不能新增注册入口。除公开竞赛检索外，个人 Skill 只读本地加密 Vault Gateway，结果必须带来源和数据时间证据。

| Skill ID | 公开/个人 | 向模型发送的数据 | 输入字段 | 输出字段 | 数据类型 | 权限 | 确定性 | 始终授权 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `personal.schedule.today` | 个人 | 指定日期最小课表摘要 | `date` | 课程、时间、地点、空闲 | 课表 | 低敏感，会话授权 | 否 | 会话内 |
| `personal.schedule.week` | 个人 | 不超过七天课表摘要 | `week_containing` 或日期范围 | 课程、时间、地点 | 课表 | 低敏感，会话授权 | 否 | 会话内 |
| `personal.academic.overview` | 个人 | 学业覆盖概览 | 无 | 学期、课程数量、缺失状态 | 成绩 | 中敏感，仅本次 | 否 | 否 |
| `personal.physical.overview` | 个人 | 最近体测概览 | 无 | 学年、总分、项目结果 | 体测 | 中敏感，仅本次 | 否 | 否 |
| `personal.erke.overview` | 个人 | 二课最小化概览 | 无 | 总分、分类完成度、最近活动 | 二课 | 低敏感，会话授权 | 否 | 会话内 |
| `campus.competition.search` | 公开 | 公开竞赛目录结果 | `keyword`、`category_slug`、`limit` | 公开竞赛条目 | 公开数据 | 无个人权限 | 否 | 不适用 |
| `personal.academic.gpa` | 个人 | 课程计算证据和结果 | 无 | GPA、公式版本、纳入/排除课程 | 成绩 | 高敏感，仅本次 | 是 | 否 |
| `personal.academic.credit_summary` | 个人 | 学分统计证据 | 无 | 已修、通过、未通过、未知学分 | 成绩 | 高敏感，仅本次 | 是 | 否 |
| `personal.academic.failure_risk` | 个人 | 未通过和未知课程摘要 | 无 | 风险课程和未知课程 | 成绩 | 高敏感，仅本次 | 是 | 否 |
| `personal.graduation.readiness` | 个人 | 毕业清单证据 | 无 | 五态要求、规则版本 | 成绩/培养方案 | 高敏感，仅本次 | 是 | 否 |
| `personal.competition.fit` | 个人 | 资格和证据摘要 | 无 | 资格状态、证据状态、推荐等级 | 成绩/公开竞赛 | 高敏感，仅本次 | 是 | 否 |
| `personal.fitness.weekly_plan` | 个人 | 课表和体测最小摘要 | `week_containing`、可选身高体重、不适标记 | BMI 场景、窗口、安全提示 | 课表/体测 | 高敏感，仅本次 | 是 | 否 |

所有 Tool Schema 默认 `additionalProperties: false`，并递归拒绝 `user_id`、`student_id`、`password`、`token`、`cookie`、`api_key` 等敏感标识。模型只能从本轮固定下发的定义中选择 Skill。
