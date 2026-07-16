# 2026 鸿蒙赛道作品说明文档模板执行契约

## 参考文件

- 权威模板：`C:\Users\zhy23\Desktop\2026中国高校计算机大赛人工智能创意赛初赛（鸿蒙赛道）作品说明文档模板.docx`
- 工作副本：`D:\python_play_do\sylg-live\scratch\application_2026\template.docx`
- SHA-256：`5E83D0410F1FB97D7074A1B63841B2261A195039645E18A757475DE27451EA34`
- 基线页数：6 页；节数：1；表格：1；内嵌图片：2。
- 基线渲染：`D:\python_play_do\sylg-live\scratch\application_2026\template-render-final`
- 样式证据：`D:\python_play_do\sylg-live\scratch\application_2026\template-style-evidence.json`

## 页面系统

- 单节 A4 纵向，页面 `7556500 x 10693400 EMU`。
- 上、下边距各 `914400 EMU`；左、右边距各 `1143000 EMU`。
- 页眉距 `540385 EMU`，页脚距 `539750 EMU`，无分栏。
- 页脚固定保留“组委会编制”文字与 `2026.06`，新增页码并入同一行右侧，避免改变正文分页。
- 模板第 1 至 4 页为保留区；第 4 页末尾已有显式分页符，作为新增正文起点。

## 字体与段落角色

- 模板既有前四页按原始直接格式保留，不重设 Normal、Footer 或表格样式。
- 新增正文遵循模板第 6 页规范：宋体；标题二号（22 磅）粗体；一级标题三号（16 磅）粗体；二级标题四号（14 磅）粗体；正文五号（10.5 磅）；单倍行距。
- 正文两端对齐、首行缩进 2 字符；标题居中；图注 9 磅、居中、深灰色。
- 新增截图全部使用行内图片，避免浮动锚点导致 Word/LibreOffice 位移。

## 表格与图片

- 原团队信息表完整保留，仅允许修正团队优势描述中的病句。
- 新增技术状态表是三列可比较记录，列宽分别约 `2.6 cm / 5.8 cm / 6.2 cm`，允许自动增高，不设置固定行高。
- 用户指定截图：
  - 社区首页：`C:\Users\zhy23\AppData\Local\Temp\codex-clipboard-4fec1312-9962-421e-9e23-941ca365e8bd.png`，`761 x 1653`。
  - 校园资讯：`C:\Users\zhy23\AppData\Local\Temp\codex-clipboard-4531ecc4-757b-43f5-8d03-540a008c0c73.png`，`764 x 1650`。
  - 校园服务：`C:\Users\zhy23\AppData\Local\Temp\codex-clipboard-048161d9-0148-446f-b2d0-f7fd40c571d2.png`，`764 x 1648`。
- 不使用智能课表截图，也不再探索其他界面。

## 内容流与编辑槽位

1. `word/document.xml` 第 1 至 4 页：保留封面、内容清单、团队信息表、原创性声明、签名与日期。
2. 团队优势描述：只将“还要多个项目经历”修正为“拥有多项项目经历”。
3. 原创性声明标题：修正书名号与右括号，不改变声明正文。
4. 删除“作品说明文档提交规范说明”及其后的模板说明文本，保留前置分页符。
5. 新增约 4 页主体：创意描述与定位、三张真实界面、技术与 AI 方案、鸿蒙适配路径、800 字以内作品介绍。
6. `word/footer1.xml`：保留现有页脚文字，在同一段右侧加入动态 PAGE 字段。
7. `word/settings.xml`：允许设置 `w:updateFields=true`，确保 Word 打开时刷新页码。

## 内容边界

- 已完成成果：Flutter/Android 原型，Go REST 服务，Python 校园数据服务，PostgreSQL、Nginx、Docker，以及仓库中可验证的社区、校园资讯、竞赛、教务、成绩、消息、评价等能力。
- 鸿蒙赛事版计划：ArkTS/ArkUI Stage 模型重构核心页面，复用既有 REST 服务，计划接入服务卡片、通知提醒和跨设备协同。
- AI 增强方案：在既有数据采集/API 基础上新增通知分类、摘要、结构化字段抽取、规则校验、去重与来源回链；不得写成已全部上线。

## 包保留策略

- 必须保持原模板文件字节级不变。
- 以下原始部件视为保留项，其 SHA-256 在最终审计中校验：
  - `customXml/item1.xml`：`490a066abc7ab8841176bee342fbd476c46c203d3a7fa0aa4a0e0b48f402240e`
  - `customXml/itemProps1.xml`：`24f337ea5f5e224582ee1462cc0f0a7a9572a6ba6bd4d808a4d48ed5283d0f6e`
  - `customXml/_rels/item1.xml.rels`：`80482f86e196171d66001e0e74d1900408a3aaf2463e54005d251b5f2db9a0b0`
  - `word/fontTable.xml`：`1bb7871cb57d18adce1f4cee43e9654aa31195036ce6a2405ac5530da1606207`
  - `word/numbering.xml`：`d5babb14c29250e60a712ef4138d2e6b52677a05d37644143bf29530d9337630`
  - `word/theme/theme1.xml`：`20b1cf0f6bd861afd2ee727424bf2da47b72e5e70232e7477547132a50c1f809`
  - `word/media/image1.png`：`a4fd27d29f30e36f17ece6406271e98ad42c9f6cc2131955348657a168a5b8cd`
  - `word/media/image2.jpeg`：`3436490a1676207a916be57cdbbc30e0de49c4c62b9faa81be5689e15ab50796`
- `word/document.xml`、关系文件、`styles.xml`、`settings.xml`、`footer1.xml`、内容类型与文档属性允许因新增正文、图片、样式和页码发生预期变化。

## 交付门槛

- 预期最终页数约 8 页，主体不超过 20 页。
- 三张截图均出现且图注相邻；无课表截图。
- 作品介绍正文（不含标题）不超过 800 个非空白字符。
- 每页渲染为 PNG 并逐页检查：无截断、重叠、空白异常、字体缺失、图片拉伸或表格破损。
- 最终再次校验模板 SHA-256 未变，并对正文、图片关系、页码字段和保留部件做结构审计。
