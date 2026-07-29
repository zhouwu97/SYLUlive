# SYLUlive 校园政策 v0.8

v0.8 将 v0.7 的混合资助材料拆为独立文档类型，并新增共享的 `Intent + Focus + Breadth` 查询契约。

- 先导入 `SYLUlive_AI学生资助政策拆分导入包_v0.8.jsonl`，完成 `inspect -> reindex -> publish`。
- 发布后以新文档替代 v0.7 的两个混合文档；本科生校级奖学金文档继续沿用。
- `school_work_study_policy` 中“恰好两门不及格”的原始转录冲突未被擅自修正，回答必须披露冲突并回查学生处正式原文。
- `policy-bundle-manifest.json` 固定独立 MCP 使用的 Bundle 和意图契约 SHA。

运行 `python build_bundle.py` 可重复生成两个 JSONL 和 Manifest。
