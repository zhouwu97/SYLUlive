# 沈阳理工大学教务处公开网站 — 结构探测报告

> 探测时间：2026-06-25
> 探测工具：`python-edu-service/tools/jwc_public_probe/`
> 目标站点：`https://jwc.sylu.edu.cn/`（公开网站，无需登录）
> 探测范围：首页 + 教务通知/教务公告各前两页 + 4 篇样例文章 + 1 次 404 边界测试

本报告所有选择器、URL、字段均来自实际探测输出（`output/*.json`），
非推测。探测脚本可重复运行验证。

---

## 1. 首页栏目与"更多"链接

首页 `<title>` 为 `沈阳理工大学教务处`，包含 5 个栏目板块。
每个板块结构为 `<div class="dynamic ..."><h2>栏目名</h2><span><a href="xxx.htm"><img src="temp/more.png"></a></span>...</div>`。
"更多"链接是一个图片（`more.png`），无文本，`<a>` 的 `href` 即栏目列表页地址。

| 栏目名 | 更多链接（相对） | 更多链接（绝对） | 首页样例文章数 | 文章 URL 前缀 |
|--------|------------------|------------------|---------------|--------------|
| 教务通知 | `jwtz.htm` | `https://jwc.sylu.edu.cn/jwtz.htm` | 9 | `info/1116/` |
| 教务公告 | `jwgg.htm` | `https://jwc.sylu.edu.cn/jwgg.htm` | 9 | `info/1119/` |
| 教改专题 | `jgzt.htm` | `https://jwc.sylu.edu.cn/jgzt.htm` | 9 | `info/1134/` |
| 教学管理文件 | `jxglwj.htm` | `https://jwc.sylu.edu.cn/jxglwj.htm` | 9 | `info/1121/` |
| 下载中心 | `xzzx/jw.htm` | `https://jwc.sylu.edu.cn/xzzx/jw.htm` | 9 | `info/1123/` 等 |

**首页样例文章选择器**：`div.vsb-space a[href*="info/"]`
**首页文章日期格式**：`[MM-DD]`（无年份，仅月日，包在 `<span>` 内）
**首页文章标题选择器**：`a > em`（`<em>` 内为标题文本）

> ⚠️ 本轮只探测"教务通知"和"教务公告"两个栏目（按 plan 要求）。
> 其余三个栏目结构相同，可复用同一套选择器。

---

## 2. 列表页分页 URL 规则

该站点采用**倒序分页**（inverted pagination），与常见 CMS 不同，需特别处理。

### 规则

| 元素 | 教务通知 | 教务公告 |
|------|---------|---------|
| 第 1 页 URL | `https://jwc.sylu.edu.cn/jwtz.htm` | `https://jwc.sylu.edu.cn/jwgg.htm` |
| 第 2 页 URL | `https://jwc.sylu.edu.cn/jwtz/139.htm` | `https://jwc.sylu.edu.cn/jwgg/9.htm` |
| 尾页 URL | `https://jwc.sylu.edu.cn/jwtz/1.htm` | `https://jwc.sylu.edu.cn/jwgg/1.htm` |
| 总页数 | 140 | 10 |
| 每页条数 | 16 | 16 |

### 公式

```
第 1 页：  <BASE>/<slug>.htm
第 k 页（k≥2）：<BASE>/<slug>/<total - k + 1>.htm
```

- 教务通知：`page_k = https://jwc.sylu.edu.cn/jwtz/{140 - k + 1}.htm`
- 教务公告：`page_k = https://jwc.sylu.edu.cn/jwgg/{10 - k + 1}.htm`

### 验证

- 教务通知 page2 = `jwtz/139.htm`，按公式 `140 - 2 + 1 = 139` ✓
- 教务公告 page2 = `jwgg/9.htm`，按公式 `10 - 2 + 1 = 9` ✓

### 分页 HTML 结构

```html
<span class="p_first p_fun"><a href="...">首页</a></span>
<span class="p_prev p_fun"><a href="...">上页</a></span>
<span class="p_no_d">1</span>                              <!-- 当前页，禁用 -->
<span class="p_no"><a href="jwtz/139.htm">2</a></span>     <!-- 页号链接 -->
...
<span class="p_no"><a href="jwtz/1.htm">140</a></span>
<span class="p_next p_fun"><a href="jwtz/139.htm">下页</a></span>
<span class="p_last p_fun"><a href="jwtz/1.htm">尾页</a></span>
```

**总页数获取方式**：解析 `span.p_no` 下 `<a>` 的最大数字文本，或从"尾页"链接的 URL 数字 +1 推算。

**生产建议**：不需要遍历全部 140 页。只需定时抓第 1 页（最新 16 条），用 `article_id` 去重即可。
翻历史页只在首次全量回填时执行，按倒序页号递减请求。

---

## 3. 列表页列表项选择器

### 列表项 HTML 结构

```html
<li id="line_u7_0">
  <span> 2026-06-23</span>
  <a href="info/1116/5946.htm"><em>关于做好我校2026年下半年全国计算机等级考试（NCRE）报名工作的通知</em></a>
</li>
```

| 字段 | 选择器 | 提取方式 | 示例值 |
|------|--------|---------|--------|
| 列表项容器 | `li[id^="line_u"]` | — | `<li id="line_u7_0">` |
| 标题 | `li a em` | `em.get_text(strip=True)` | `关于做好我校2026年下半年...` |
| 日期 | `li > span` | `span.get_text(strip=True)` | `2026-06-23` |
| 文章 URL | `li > a[href]` | `a["href"]`，根相对 | `info/1116/5946.htm` |
| article_id | URL 末段数字 | 正则 `/(\d+)\.htm$` | `5946` |
| li 序号 | `li[id]` | `id` 属性 | `line_u7_0` |

**日期格式**：`YYYY-MM-DD`（完整日期含年份，`<span>` 文本前有一个空格）
**列表项 CSS 类**：无（`<li>` 无 class 属性）
**每页条数**：16 条（实测两栏目一致）

---

## 4. 文章详情页选择器

### 文章页 DOM 结构

```html
<form name="_newscontent_fromname">
  <div class="main_content">
    <div class="main_contit">
      <h2>文章标题</h2>
      <p>作者:教务管理科    时间：2026-06-23    点击数：<script>...</script></p>
    </div>
    <div class="main_conDiv" id="vsb_content_XXXX">
      <div class="v_news_content">
        <!-- 正文 HTML -->
      </div>
      <div id="div_vote_id"></div>
      <!-- 附件（如有） -->
      <p><UL style="list-style-type:none;">
        <li>附件【<a href="/system/_content/download.jsp?...">filename.ext</a>】已下载...次</li>
      </UL></p>
      <!-- 上/下一篇 -->
      <div class="main_art"><ul>
        <li><lable>上一篇：</lable><a href="5946.htm">上一篇标题</a></li>
        <li><lable>下一篇：</lable><a href="5941.htm">下一篇标题</a></li>
      </ul></div>
    </div>
  </div>
</form>
```

### 选择器汇总（实测 4 篇文章全部命中）

| 字段 | 选择器 | 提取方式 | 备注 |
|------|--------|---------|------|
| 标题 | `.main_contit h2` | `get_text(strip=True)` | 4/4 命中 |
| 元信息 | `.main_contit p` | 文本正则提取 | 含作者+日期+点击数 |
| 正文容器 | `.v_news_content` | 取 `innerHTML` | **4/4 命中，稳定** |
| 附件链接 | `a[href*="download.jsp"]` | `href` + `get_text()` | 仅在有附件时出现 |
| 上/下一篇 | `.main_art ul li` | `<lable>` + `<a>` | 注意源码是 `<lable>` 非 `<label>` |

### 元信息解析

`.main_contit p` 文本格式固定：
```
作者:教务管理科    时间：2026-06-23    点击数：
```

正则提取：
- 作者/部门：`作者[:：]\s*(\S+?)\s+`
- 发布日期：`时间[:：]\s*(\d{4}-\d{2}-\d{2})`
- 点击数：动态加载（`<script>_showDynClicks(...)</script>`），**不可静态抓取**，生产不需要

### 实测样例

| article_id | 标题 | 日期 | 来源 | 正文长度 | 附件数 |
|-----------|------|------|------|---------|-------|
| 5946 | NCRE报名通知 | 2026-06-23 | 教务管理科 | 636 字 | 0 |
| 5903 | 毕业论文培训 | 2026-05-18 | 实践教学科 | 394 字 | 0 |
| 5737 | 日课表结构 | 2025-11-03 | 教务管理科 | 0 字（仅附件） | 1 (.pdf) |
| 5945 | 经管学院考试安排 | 2026-06-23 | 教务管理科 | 5 字（"详见附件："） | 1 (.xls) |

---

## 5. 附件提取方式

### 附件 HTML 结构

```html
<p>
  <UL style="list-style-type:none;">
    <li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1615111502&wbfileid=12241422" target="_blank">2025-2026-2经济管理学院期末考试安排 17周 .xls</a>】已下载<span id="nattach...">...</span>次</li>
  </UL>
</p>
```

### 提取方法

| 字段 | 提取方式 | 示例 |
|------|---------|------|
| 文件名 | `a.get_text(strip=True)` | `2025-2026-2经济管理学院期末考试安排 17周 .xls` |
| 下载 URL | `a["href"]`（根相对，需补全 `https://jwc.sylu.edu.cn`） | `https://jwc.sylu.edu.cn/system/_content/download.jsp?...&wbfileid=12241422` |
| 文件扩展名 | 文件名末段 `.` 之后 | `xls`、`pdf`、`rar` |
| 选择器 | `a[href*="download.jsp"]`（在 `.main_conDiv` 范围内） | — |

### 附件 URL 行为（HEAD 探测）

| 探测项 | 结果 |
|--------|------|
| HEAD 请求状态 | `200` |
| Content-Type | `text/html;charset=UTF-8`（**非文件 MIME**） |
| Content-Length | `None`（chunked 或未知） |

**重要发现**：`download.jsp` 是一个**中间跳转页**，不是直接文件链接。
HEAD 返回 `text/html`，说明服务器先返回一个 HTML 页面再由 JavaScript 跳转到实际文件。
生产抓取时：
- 第一版只记录文件名和原 URL，不下载文件体（符合 plan 要求）
- 如需获取实际文件大小和 MIME，需跟随重定向并检测最终响应头（本轮不做）

### 附件选择器稳定性

`a[href*="download.jsp"]` 在 2/2 带附件的文章中命中。
无附件的文章（5946、5903）该选择器返回空列表，符合预期。

---

## 6. 图片与相对 URL 补全规则

### 正文内图片

文章正文（`.v_news_content`）中的图片使用**根相对 URL**：

```html
<img class="img_vsb_content"
     orisrc="/__local/0/5D/B7/A5A491254473F9042F624B19A42_75D398A0_A4E8.png"
     src="/__local/0/5D/B7/A5A491254473F9042F624B19A42_75D398A0_A4E8.png"
     vheight="..." vwidth="..."/>
```

**补全规则**：`src` 以 `/` 开头，补全为 `https://jwc.sylu.edu.cn` + `src`。
- 输入：`/__local/0/5D/B7/...png`
- 输出：`https://jwc.sylu.edu.cn/__local/0/5D/B7/...png`

实测：`sanitize_html.py` 使用 `urljoin(base_url, src)` 正确补全。

### 导航/模板图片

页面导航图片使用**页相对 URL**（如 `../../images/logo.png`），
位于 `.v_news_content` 之外，生产抓取时不需要提取。

### `orisrc` 属性

源 HTML 中 `<img>` 同时有 `orisrc` 和 `src` 属性，值相同。
`orisrc` 是该 CMS 的自定义属性，不在白名单中，`sanitize_html` 会移除。
生产入库只保留 `src` 即可。

### 补全基准

| URL 类型 | 示例 | 补全基准 | 正确结果 |
|---------|------|---------|---------|
| 根相对 `/...` | `/__local/0/5D/...png` | `https://jwc.sylu.edu.cn` | `https://jwc.sylu.edu.cn/__local/0/5D/...png` |
| 根相对 `/system/...` | `/system/_content/download.jsp?...` | `https://jwc.sylu.edu.cn` | `https://jwc.sylu.edu.cn/system/_content/download.jsp?...` |
| 页相对 `XXXX.htm` | `5946.htm`（上/下一篇） | **文章页 URL** | `https://jwc.sylu.edu.cn/info/1116/5946.htm` |
| 绝对 `https://...` | `https://ncre-bm.neea.cn/` | 不需补全 | 原样保留 |

> ⚠️ **上/下一篇链接使用页相对 URL**（如 `5945.htm`），必须以文章页 URL 为基准用 `urljoin` 解析，
> 不能用站点根作为基准，否则会错误解析为 `https://jwc.sylu.edu.cn/5945.htm`（不存在）。
> 本探针第一版有此 bug，已修复（见 `inspect_article.py` 中 `resolve(a["href"], url)`）。

---

## 7. 页面编码

| 位置 | 编码 | 检测方式 |
|------|------|---------|
| 首页 | UTF-8 | `<meta charset="utf-8">` |
| 列表页 | UTF-8 | 同上 |
| 文章页 | UTF-8 | 同上 |
| 404 页 | UTF-8 | `<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />` |

**结论**：全站 UTF-8，无需 GBK 转码。`httpx` 默认按 meta charset 解码，`r.text` 直接可用。

---

## 8. 置顶/重复文章检测

### 置顶文章

探测结果：**未观察到置顶文章标记**。

- 列表项 `<li>` 无 CSS class（`li_classes: []`）
- 未发现 `.zd`、`.top`、`.sticky`、`.hot` 等置顶类名
- 首页和列表页的条目顺序按发布日期降序排列，无异位条目

**生产建议**：当前无需处理置顶。若未来出现置顶，检测方式为：
1. `<li>` 是否新增 class
2. 列表顺序是否与日期降序不一致
3. 标题前是否有 `[置顶]` 前缀

### 重复文章

- 教务通知第 1 页：16 条，`article_id` 无重复
- 教务公告第 1 页：16 条，`article_id` 无重复
- 跨栏目无重复（不同栏目 `category_id` 不同：1116 vs 1119）

**去重键**：`article_id`（URL 末段数字）在栏目内唯一。
跨栏目可用 `source_url` 全 URL 或 `category_id + article_id` 组合键。

---

## 9. 登录需求确认

| 测试项 | URL | HTTP 状态 | 需要登录？ | 备注 |
|--------|-----|----------|-----------|------|
| 首页 | `https://jwc.sylu.edu.cn/` | 200 | 否 | 完整 HTML |
| 教务通知列表 | `https://jwc.sylu.edu.cn/jwtz.htm` | 200 | 否 | 16 条列表 |
| 教务通知 page2 | `https://jwc.sylu.edu.cn/jwtz/139.htm` | 200 | 否 | 16 条列表 |
| 教务公告列表 | `https://jwc.sylu.edu.cn/jwgg.htm` | 200 | 否 | 16 条列表 |
| 教务公告 page2 | `https://jwc.sylu.edu.cn/jwgg/9.htm` | 200 | 否 | 16 条列表 |
| 文章 5946 | `info/1116/5946.htm` | 200 | 否 | 完整正文 |
| 文章 5903 | `info/1119/5903.htm` | 200 | 否 | 完整正文 |
| 文章 5737 | `info/1119/5737.htm` | 200 | 否 | 完整正文 + 附件链接 |
| 文章 5945 | `info/1116/5945.htm` | 200 | 否 | 完整正文 + 附件链接 |
| 附件 .pdf | `download.jsp?...wbfileid=12230681` | 200 (HEAD) | 否 | 返回中间跳转页 |
| 附件 .xls | `download.jsp?...wbfileid=12241422` | 200 (HEAD) | 否 | 返回中间跳转页 |

**结论**：所有探测的页面和附件 URL **均无需登录**。
未检测到登录表单、重定向到登录页、403、"请登录"文本或任何登录标记。
`login_markers_found: []`，`requires_login: false`（全部 4 篇文章）。

> 该站点与需要登录的教务管理系统 `jxw.sylu.edu.cn` 是完全独立的服务，
> 公开通知不含任何个人或成绩数据，适合服务器统一抓取。

---

## 10. 边界行为

### 404 行为

| 测试 | 结果 |
|------|------|
| URL | `https://jwc.sylu.edu.cn/info/1116/99999999.htm`（故意构造的不存在 ID） |
| HTTP 状态 | `404` |
| 响应体大小 | 1627 字节 |
| 页面标题 | `404错误提示` |
| Content-Type | `text/html` |

服务器返回**标准 HTTP 404 状态码**（非 200 + 自定义错误页），
生产抓取可通过状态码直接判断文章是否存在。

### 超时与重试

探针配置：超时 15s，最多 3 次重试，指数退避（0.5s → 1s → 2s）。
本轮所有请求均首次成功，未触发重试。

### 请求间隔

所有请求间至少 500ms 间隔（`asyncio.sleep(0.5)`）。
单线程顺序执行，无并发。未触发任何限流、封禁或验证码。

---

## 11. 推荐的生产抓取字段与去重键

### 文章字段

```json
{
  "article_id": "5946",                    // URL 末段数字，栏目内唯一
  "category": "教务通知",                   // 栏目名
  "category_id": "1116",                   // URL 中段，栏目唯一
  "source_url": "https://jwc.sylu.edu.cn/info/1116/5946.htm",
  "title": "关于做好我校2026年下半年全国计算机等级考试（NCRE）报名工作的通知",
  "publish_date": "2026-06-23",            // YYYY-MM-DD
  "author_department": "教务管理科",         // 来源部门
  "content_html": "<p>各学院：...</p>",     // 白名单清洗后的 HTML
  "content_text": "各学院：根据...",        // 纯文本（搜索用）
  "attachments": [
    {
      "name": "2025-2026-2经济管理学院期末考试安排 17周 .xls",
      "url": "https://jwc.sylu.edu.cn/system/_content/download.jsp?...",
      "extension": "xls"
    }
  ],
  "has_attachment": true,
  "crawled_at": "2026-06-25T12:00:00+08:00"
}
```

### 去重键

| 键 | 唯一性 | 推荐度 | 备注 |
|----|--------|--------|------|
| `article_id` | 栏目内唯一 | ⚠️ 不够 | 不同栏目可能有相同 ID（实测未出现，但不保证） |
| `category_id + article_id` | 全站唯一 | ✅ 推荐 | `1116:5946` 形式 |
| `source_url` | 全站唯一 | ✅ 推荐 | URL 本身唯一，但更长 |

**生产推荐**：用 `source_url` 做主键（或 `category_id + article_id` 组合键）。
检测更新时比较 `title + publish_date + content_html` 的哈希值。

### 列表接口建议字段

```json
{
  "items": [
    {
      "article_id": "5946",
      "category": "教务通知",
      "title": "......",
      "publish_date": "2026-06-23",
      "source_url": "https://jwc.sylu.edu.cn/info/1116/5946.htm",
      "has_attachment": true
    }
  ],
  "page": 1,
  "total_pages": 140,
  "total_items_estimate": null
}
```

### 生产抓取策略建议

1. **定时频率**：每 15–30 分钟抓取栏目第 1 页（16 条最新）
2. **去重**：用 `source_url` 去重，新 `article_id` 触发通知
3. **更新检测**：标题、日期、正文 HTML 哈希变化时更新
4. **请求间隔**：≥ 500ms，单线程
5. **User-Agent**：固定标识，如 `SYULive-JWC-Crawler/1.0 (+contact)`
6. **不执行 JS**：静态解析 HTML 即可，`点击数` 等动态字段不抓
7. **HTML 清洗**：白名单方式（参见 `sanitize_html.py`），入库前移除 script/style/事件属性
8. **附件**：第一版只存名称和原 URL，不下载文件体
9. **URL 补全**：根相对用站点根做基准；上/下一篇用文章页 URL 做基准（`urljoin`）
10. **全量回填**：首次运行时按倒序分页遍历历史页（page 2 = `<slug>/<total-1>.htm`）

---

## 12. 探针文件清单

| 文件 | 用途 | 是否提交 git |
|------|------|-------------|
| `inspect_homepage.py` | 首页结构探针 | ✅ |
| `inspect_category.py` | 栏目列表页探针 | ✅ |
| `inspect_article.py` | 文章详情页探针 | ✅ |
| `sanitize_html.py` | 白名单 HTML 清洗器 | ✅ |
| `tests/conftest.py` | pytest 路径配置 | ✅ |
| `tests/test_sanitize_html.py` | 清洗器单元测试（52 通过） | ✅ |
| `README.md` | 使用说明 | ✅ |
| `.gitignore` | 忽略 output/ 原始文件 | ✅ |
| `output/.gitkeep` | 占位 | ✅ |
| `report/jwc_structure_report.md` | 本报告 | ✅ |
| `output/*.html, *.json` | 探针原始输出 | ❌ gitignored |

---

## 13. 停止条件

本轮只做结构探测和报告，**不修改**：

- `python-edu-service/services/`（生产 crawler — 后续独立任务）
- `python-edu-service/routers/`（API 路由）
- `python-edu-service/models/`（数据库模型）
- `python-edu-service/main.py`、`config.py`
- `client/lib/screens/campus_screen.dart`（Flutter 校园页）
- `server/`（Go API）
- 数据库模型或迁移
- 软件公告逻辑（`/notices`、`/announcements`）

等待人工审查本报告后再决定是否进入正式 crawler 开发。

---

## 14. 验证命令

```bash
cd python-edu-service
python -m pytest tools/jwc_public_probe -q          # 52 passed
python tools/jwc_public_probe/inspect_homepage.py   # 首页 → 5 栏目, 9 样例/栏目
python tools/jwc_public_probe/inspect_category.py   # 2 栏目 × 2 页, 16 条/页
python tools/jwc_public_probe/inspect_article.py    # 4 篇文章 + 404 测试
git diff --check                                     # 无空白错误
git status --short                                   # 仅 tools/jwc_public_probe/ 下新增文件
```
