# 素材生成

## 生图工具

- **Codex**：优先使用内置的图像生成工具，参考图作为输入图片一起传入。
- **其他代理，或内置工具不可用时**：用 `imagegen-sunburst` 的脚本（Codex 中路径为 `~/.codex/skills/imagegen-sunburst/scripts/`，Claude Code 中为 `~/.claude/skills/imagegen-sunburst/scripts/`）。`--size`、`--quality`、`--background` 是全局参数，要写在子命令之前；`edit` 的 `--ref` 可以重复传入。首次使用先加 `--dry-run` 确认配置。提示词先写进 `concept/prompts/<槽位>.txt` 再读入，方便重做时复用：

```powershell
python "$HOME/.codex/skills/imagegen-sunburst/scripts/image_gen_sunburst.py" --background transparent --quality high edit --prompt (Get-Content -Raw <WORK>/concept/prompts/stickers.txt) --ref <锚点A> --ref <表情1> --out <WORK>/gen/stickers-sheet.png
```

## 顺序

1. **贴纸表**（先做，定画风）：3×2 宫格、透明背景，6 个 Q 版动作取自 `character.md` 的「性格→动作」表。提示词写明：每格一个完整角色，四周留白，格与格之间不重叠，不画格线，不写文字。核对通过后切开：

   ```powershell
   flutter test --no-pub --dart-define="TOOL=slice" --dart-define="IN=<WORK>/gen/stickers-sheet.png" --dart-define="GRID=3x2" --dart-define="OUT=<WORK>/gen/stickers" ../skills/sylulive-theme/scripts/asset_tools_test.dart
   ```

   切出的每张图会自动裁掉透明边，命名为 `01.png`–`06.png`。
2. **底栏图标表**：5×2 宫格（上排常态、下排选中态），透明背景，用和贴纸表相同的画风参考，切开后用 `fit` 缩放到 192×192。
3. **空态、错误插画**：可以直接从贴纸表里选两个表情，也可以单独生成（参考贴纸表），长边 ≥512。
4. **母题纹理和区块记号**：小尺寸透明图（纹理块 256、记号 96–144）。图形要简单，生成后缩小检查是否清楚。
5. **页头**（明暗共 4–6 张）：21:9 画布，参考图依次为身份锚点、动作参考、贴纸表（画风）。提示词写明构图区域、留白侧、「整个头部和耳朵在画面内，头顶留白」。成图用 `fit` 裁切到 2000×760 左右。
6. **壁纸**：9:19.5 竖图，渐变加纹样加一角小 Q 版，用 `fit` 输出 1080×2340。

## 提示词骨架

```text
参考图 1 是角色身份锚点，参考图 2–3 是表情或动作参考，参考图 4 是本套主题的画风基准。
画：<画面内容（来自 slots.md）>。
角色标志物（全部保留，不要省略）：<逐项粘贴标志物清单>。
构图：<比例>，人物位于<区域>，<留白区域>保持低细节，整个头部、呆毛和耳朵在画面内并留出头顶空间。
画风：<theme.md 的统一画风描述>，柔和赛璐璐上色，干净线稿，与参考图 4 一致。
配色：<theme.md 配色>。
不要：文字、logo、水印、签名、UI 元素、多余的人物、写实风格。忠实于参考比好看更重要。
```

全部槽位共用同一段画风和配色描述，只替换「画」和「构图」两行。

## 后处理工具

`scripts/asset_tools_test.dart` 只依赖客户端已有的 `package:image`，在 `client/` 下运行：

| TOOL | 参数 | 作用 |
| --- | --- | --- |
| `contact` | `IN` 目录、`OUT` 文件 | 为目录里的图片生成带编号的总览，每张最多 48 格，超过时自动分成多张 |
| `slice` | `IN` 宫格图、`GRID`（如 `3x2`）、`OUT` 目录 | 按宫格切开，并裁掉每格四周的透明边 |
| `fit` | `IN`、`OUT`、`SIZE`（如 `2000x760`）、可选 `FOCUS`（如 `0.65,0.4`） | 按焦点 cover 裁切并缩放到目标尺寸；`OUT` 后缀为 `.jpg` 时输出质量 90 的 JPEG |

## 失败处理

- 标志物缺失：在提示词里把缺的那项放到第一句并加粗描述，再重做一次；连续 3 次失败，就改用原画裁切或扩图。
- 画风漂移：把画风基准换成最满意的那张成图，重做漂移的那张。
- 宫格切不开（人物越过格线）：在提示词里加大格间距，并写明「每格只有一个角色」。
