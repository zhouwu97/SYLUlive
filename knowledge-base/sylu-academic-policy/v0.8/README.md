# SYLUlive 校园政策 v0.8

v0.8 将 v0.7 的混合资助材料拆为独立文档类型，并新增共享的 `Intent + Focus + Breadth` 查询契约；同时补入“本科生学士学位授予条件”校内核验规则卡，用于将学位问答优先路由到校园口径。该规则卡在正式发布前仍须由教务处现行正式细则原件复核并替换。

- 使用管理端发布工具时导入 `SYLUlive_AI学生资助政策完整导入包_v0.8.jsonl`，其中包含沿用的本科生校级奖学金和 8 份拆分资助政策，完成 `inspect -> reindex -> publish`。
- 只替代已发布的 v0.7 混合资助文档时，可使用 `SYLUlive_AI学生资助政策拆分导入包_v0.8.jsonl`。
- 发布并抽测通过后，根据远端清单显式退役 v0.7 的两个混合文档；拆分文档的 `document_type` 不同，发布工具不会自动替代它们。
- 本科生校级奖学金文档继续沿用；远端已有相同内容 hash 时，发布 dry-run 会将其标记为 `skip`。
- `school_work_study_policy` 中“恰好两门不及格”的原始转录冲突未被擅自修正，回答必须披露冲突并回查学生处正式原文。
- `policy-bundle-manifest.json` 固定独立 MCP 使用的 Bundle 和意图契约 SHA。

运行 `python build_bundle.py` 可重复生成三个 JSONL 和独立 MCP Manifest；管理端发布清单为 `release-manifest.v0.8.json`。
