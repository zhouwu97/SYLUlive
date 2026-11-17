# 正文 Emoji 字体

`noto-color-emoji-v2.051.woff2` 用于帖子标题、摘要、正文和评论中的 Unicode Emoji。中文、数字与标点不使用此字体。字体约 1.97 MB，由站点同源按需加载，不连接在线字体服务；加载失败时保留原字符并回退系统彩色 Emoji。

- 上游：[googlefonts/noto-emoji v2.051](https://github.com/googlefonts/noto-emoji/releases/tag/v2.051)。
- 原始文件：[`fonts/Noto-COLRv1.ttf`](https://github.com/googlefonts/noto-emoji/blob/v2.051/fonts/Noto-COLRv1.ttf)。
- 上游格式：COLRv1 + CPAL；保留完整字形，仅转换为 WOFF2。
- 许可：SIL Open Font License 1.1，随站点分发于 `web/public/licenses/NotoColorEmoji-OFL.txt`；版权信息保留在字体 name 表。
- 原始 TTF SHA-256：`0ae57fe58645638523ba35f388d93739d292539a9acb84df5700c81b1e1a28d2`。
- WOFF2 SHA-256：`eea43aa18f7ae8ac50828d3b0907d2a881d0896a8ca4f5f6da471beecc7c13a2`。
- 上游版权：Copyright 2022 Google Inc.（字体内嵌 name 表）。

使用 FontTools 4.61.1 与 Brotli 1.2.0 转换，保留上游时间戳以便复现：

```python
from fontTools.ttLib import TTFont

font = TTFont("Noto-COLRv1.ttf", recalcTimestamp=False)
font.flavor = "woff2"
font.save("noto-color-emoji-v2.051.woff2")
```

不要将仅含 OpenType SVG 字形的字体替换进来：Chromium 可能报告加载成功，却仍回退系统字形。验收使用 `web/e2e/component-finish.spec.ts` 读取实际渲染字体，并检查组合 Emoji、复制和加载失败路径。
