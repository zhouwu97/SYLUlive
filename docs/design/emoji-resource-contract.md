# Emoji 资源契约

状态：M0–M7 代码实现与关键回归已接入（2026-09-20）。执行范围以完整实施计划的 v2 收束版为准，保留旧收藏、消息和贴图目录协议。

## 1. 消费者清单

| 场景 | 现有入口 | 仍保留的旧字段/服务 |
| --- | --- | --- |
| 私信输入 | `client/lib/screens/chat_detail_screen.dart`、`widgets/emoji/app_emoji_panel.dart` | `sticker_id`、`file_id`、`EmojiFavoriteService` |
| 私信草稿/发送/重试 | `client/lib/providers/message_provider.dart` | `Conversation.stickerId`、`Message.FileID` |
| 私信历史/预览 | `client/lib/models/conversation.dart`、`chat_detail_screen.dart` | 旧消息 JSON |
| 帖子回复 | `controllers/post_reply_composer_controller.dart`、`post_detail_screen.dart` | `PostReplyDraft.sticker`、收藏图片上传 |
| 收藏 | `services/emoji_favorite_service.dart`、`emoji_favorite_repository.dart` | 本地 v1/v2 缓存和服务端收藏 API |
| Recent | `features/emoji/application/emoji_recent_manager.dart` | `emoji_recent_v1` 迁移至账号隔离的 v2 |
| 内置资源 | `widgets/emoji/sticker_catalog.dart`、`emoji_catalog.dart` | 生成文件和资源路径不移动 |
| Web 官方表情/收藏 | `web/src/emoji.tsx`、`web/src/emoji-selection.ts` | 官方目录、`sticker_id` / `asset_key` / `file_id`；尚未接入社区商城与创作流程 |

## 2. AssetKey

统一键使用结构化 `EmojiAssetKey`，业务层禁止自行 `split(':')`：

```text
unicode:<unicode>
builtin:<packId>:<assetId>
official:<packId>:<assetId>
private:<serverAssetId>
private:<packId>:<assetId>   # 私有 Pack 预留
local:<localPackUuid>:<assetId>
```

`unicode` 不允许 `packId`；`builtin`、`official`、`local` 必须带 `packId`；`private` 兼容服务端资产的两段式键。键只表达逻辑资源身份，不表达收藏、安装或权限状态。

## 3. 资源与关系

`EmojiAsset` 是不可变资源描述；`EmojiFavoriteItem`、Recent 记录和 Pack 安装状态是独立关系。第一阶段通过 Adapter 接入旧模型，不删除旧模型。

```text
EmojiAsset
  ├─ Favorite（用户关系）
  ├─ Recent（使用关系）
  └─ Pack / Installation（来源与本机状态）
```

图片消息同时保存：

- `assetKey`：逻辑资源身份，通过可选的 `asset_key` 保存和返回。
- `fileId`：文件实体和历史引用，保持 `int`，现阶段不删除。
- `stickerId`：旧内置贴图兼容字段。
- `packId`：通过可选的 `pack_id` 保存来源，不能替代 `fileId`，也不授予文件访问权限。

取消收藏或删除本地 Pack 不删除历史消息引用的 File。

## 4. Hash 与信任

| 名称 | 对象 | 用途 | 当前阶段 |
| --- | --- | --- | --- |
| `manifestSha256` | 规范化 manifest bytes | Catalog/Manifest 校验 | 冻结 |
| `packageAssetSha256` | 包内资源最终 bytes | 导入完整性 | 冻结 |
| `canonicalFileHash` | 服务端 NormalizeEmoji 后 bytes | 物理文件去重 | 冻结 |
| `archiveSha256` | 完整 `.sylupack` bytes | 归档传输预留 | 当前官方包逐资源下载，不使用归档 Hash |

Hash 不代表权限。相同内容可以复用物理文件，但不同用户仍必须有独立的拥有关系和服务端鉴权。

信任等级只能来自 APK 编译配置或 HTTPS 官方 Catalog：

```text
bundledOfficial / serverOfficial / privateOwned / localUntrusted
```

Manifest 中的 `official` 字段不能提升信任等级。

## 5. 服务端现状

当前复用：

- `GET/POST/DELETE /api/emoji/favorites`
- `POST /api/emoji/favorites/from-message`
- `POST /api/emoji/favorites/from-public-image`
- 收藏图片的鉴权缩略图/原图接口
- 消息 `file_id`、`sticker_id` 及文件引用计数

官方 Pack Catalog/Download API 已接入服务端发布审核的内嵌资源：

- `GET /api/emoji/packs`
- `GET /api/emoji/packs/:id`
- `GET /api/emoji/packs/:id/manifest`
- `GET /api/emoji/packs/:id/assets/:assetId`（Range / If-Range）

Manifest 使用递归排序键的紧凑 JSON；客户端先验证目录中的 Manifest Hash，再验证每项资源。客户端下载器只接受 HTTPS 官方目录并禁止重定向；导入器不能依据包内声明提升信任等级。

## 6. 实现与验收边界

| 阶段 | 已接入的行为 | 关键验证 |
| --- | --- | --- |
| M0/M1 | 统一身份、旧资源 Adapter、Resolver，消息与回复可选身份字段 | 身份解析、兼容测试、服务端保存和返回 |
| M2 | Unicode 完整字符、Sticker、图片 Recent；成功后记录；账号隔离；匿名认领；100 项上限；清空 | 失败不记录、切号、迁移、合并不膨胀、组合 Emoji |
| M3 | 本地安装索引、不可变版本、启用/禁用、排序、实际磁盘统计、删除 | 重启持久化、同版本保护、删除保留历史 File |
| M4 | Staging、Hash/解码校验、Journal、目录备份、索引切换、恢复、回滚 | 提交前后故障注入、回滚中断、损坏同版本重装 |
| M5 | ZIP 路径/链接/数量/体积/图片限制，离线进入 Installer | 非法包拒绝、合法包安装、关闭开关不能调用导入 |
| M6 | Recent 一级入口；独立管理页；详情、排序、删除、损坏状态 | 明暗主题、1.3× 字号、空态、切号、管理交互 |
| M7 | 官方目录、逐资源下载、暂停/恢复、任务持久化、续传、重试、更新和回滚 | 跨实例断点恢复、断网失败、Hash、HTTPS、Range |

默认 `officialPackDownload=true`、`customPackImport=true`。原生客户端支持图片多选、普通图片 ZIP 和 `.sylupack`，先校验预览再确认安装；免费商城和公开投稿见第 7 节，不提供私有云同步或对外导出分享。

删除安装只清理本机 Pack 目录；消息仍使用已有 `file_id` / `sticker_id` 展示。服务端通过现有 AutoMigrate 增加消息、回复可选身份列，新接口需要随服务端发布。

本次验证是自动化关键链路回归；仓库私聊开关关闭导致旧客户端私聊端到端测试跳过，不能据此宣称真机发送验收或生产部署完成。本地 Pack 依赖文件系统，当前以原生客户端为交付目标。

Web 当前只读取默认官方目录与收藏，没有请求 `include_community=true`，也没有创作者申请、投稿和本机安装流程。Web 的资源身份及发送仍按旧官方契约运行，不能把原生商城链路的通过记录作为 Web 新功能验收。

## 7. 本地导入与社区投稿

产品流程、创作者权限、自动派生图与不可变作品版本以 [免费商城方案](emoji-creator-store-plan.md) 和 [ADR-003](adr/003-free-emoji-store-and-creator-access.md) 为准。新增投稿必须先开通独立创作者权限，不自动提升历史作者身份。公开展示元数据不进入既有 Manifest Hash。

- “表情管理 → 添加”提供相册、文件、免费商城和创作中心入口。预览阶段不写安装目录；确认后只写当前账号的本机目录。普通图片集按内容去重；重复导入复用资源身份，可改名并启用，恢复/版本保护仍由 Installer 负责。
- Manifest ZIP 继续校验路径、CRC、声明清单、大小、Hash、MIME 与全部图像帧；普通图片 ZIP 自动生成清单，不接受混入的程序等非图片文件，忽略 macOS 元数据。
- 服务端目录使用 `source=community`；旧目录不带 source 时仍为 official。社区包稳定 ID 为服务端生成的 `community-<uuid>`，各不可变版本经单独审核，旧 v1 缺少版本族字段时回退自身 ID。社区包安装使用 `localUntrusted` 与 `local:<community-id>:<asset-id>`，不冒领 official 命名空间；审核状态与资源信任分开，UI 按 source 显示“校园分享 · 已审核”。新客户端显式传 `include_community=true` 才收到社区包，旧客户端继续只看到内嵌官方包。
- 待审、驳回和下架的预览仅作者/管理员可访问；公开与私有资源均禁止 CDN 缓存，私有预览使用绑定原会话的认证请求。下架或撤回后后续公开请求返回 404；已安装副本不远程删除。
- 投稿状态为 `pending → published / rejected`、新版本通过时原发布版转 `superseded`、下架转 `unpublished`，作者可撤回。待审版本不覆盖商城当前版；下架后旧版本也不可公开读取。审核使用事务/条件更新，不能审核自己投稿。每个本机制作草稿持久保存独立幂等意图，同一内容的失败重试或重开草稿复用键，提交成功清理草稿。
- 图片先在服务端限制尺寸、帧数和解码预算，再规范化保存。文件存于现有持久卷的 `.emoji-submissions`，不产生可公开的普通 File 记录。

对应文字中的 U+2028/U+2029 沿用既有服务端规则转为空格，避免 Go/Dart 对行分隔符的 JSON 编码差异；普通字符与字面量反斜线保持原意，不改既有 Manifest/Hash。

接口和额度的唯一维护入口见 [服务端 API](../../server/API.md#表情包导入投稿与审核)，发布/回退见 [运维说明](../ops/emoji-packs.md)，本次验证范围见 [完整链路验收](../reports/2026-11-03-emoji-full-chain-verification.md)。

## 8. ZIP 与 sylupack 制作格式

本节说明当前导入器实际接受的格式，不增加新协议。普通用户可以直接选图；公开投稿通过创作中心编辑资料，不要求手写清单或手工打包。

### 8.1 两种导入方式

| 类型 | 清单要求 | 图片与文字的对应方式 |
| --- | --- | --- |
| 普通图片 `.zip` | 不需要 `manifest.json`，系统自动生成 | 图片文件名去掉扩展名，例如 `开心.png` 对应“开心”；子目录名不作为文字 |
| 带清单 `.zip` / `.sylupack` | ZIP 根目录必须有大小写一致的 `manifest.json` | `assets` 数组逐项声明 `path` 与 `name` |

`.sylupack` 是 ZIP 容器使用专用扩展名。普通 ZIP 一旦包含根目录 `manifest.json`，也按带清单的严格规则校验。不能把未提供清单的图片 ZIP 仅改扩展名为 `.sylupack`。

普通图片 ZIP 只接受 PNG、JPG/JPEG、GIF，忽略 `__MACOSX/` 与 `.DS_Store` 元数据；相同图片按文件内容去重。不要附带说明文档、CSV 或其他非图片文件；没有清单时，额外的缩略图图片也会被当成一张表情。

### 8.2 带清单的目录与 JSON

直接压缩以下内容，不能在外面再套一层目录：

```text
日常.sylupack
├─ manifest.json
└─ assets/
   └─ happy.png
```

`manifest.json` 使用 UTF-8 JSON。以下只展示字段结构：`sha256`、字节数、宽高是示意值，制作时必须按实际图片计算，不能照抄后直接导入。

```json
{
  "schema_version": 1,
  "pack_id": "daily-reactions",
  "name": "日常反应",
  "version": 1,
  "total_size": 1024,
  "assets": [
    {
      "id": "happy-001",
      "path": "assets/happy.png",
      "name": "开心",
      "keywords": ["高兴", "赞同"],
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "mime_type": "image/png",
      "file_size": 1024,
      "width": 128,
      "height": 128,
      "animated": false
    }
  ]
}
```

| 字段 | 要求与含义 |
| --- | --- |
| `schema_version` | 必填，当前只能为整数 `1` |
| `pack_id` | 必填，非空且不能含 `:`；表示来源包身份，本机导入仍分配独立的 `local-…` ID |
| 根级 `name` | 可选，导入预览的包名，缺省使用归档文件名；属于导入展示资料，不进入规范化 Manifest |
| `version` | 必填，整数且至少为 `1`；不能指定商城作品的服务端版本 |
| `total_size` | 必填，所有 `assets[].file_size` 的总和，单位字节；不包含清单自身和 ZIP 开销 |
| `assets` | 必填，1–500 项，按数组顺序导入和展示 |
| `assets[].id` | 必填，包内唯一、非空、不能含 `:`；资源的逻辑标识，不是文件名 |
| `assets[].path` | 必填，ZIP 内图片的完整相对路径，大小写必须与实际文件一致；用 `/`，不能使用绝对路径、反斜线或 `..` |
| `assets[].name` | 必填，非空的逐张对应文字，例如“开心”；用于图片语义说明及当前名称筛选，不会把文字绘制到图片上 |
| `assets[].keywords` | 可选字符串数组，缺省 `[]`；作为资源元数据保留，当前管理页和输入面板的筛选只匹配 `name`，不匹配该数组 |
| `assets[].sha256` | 必填，对该图片原始文件字节计算的 64 位十六进制 SHA-256；不是文件名、ZIP 或 Base64 文本的 Hash |
| `assets[].mime_type` | 必填，使用小写 `image/png`、`image/jpeg` 或 `image/gif`，必须与图片实际内容一致 |
| `assets[].file_size` | 必填，该图片文件的实际字节数，必须精确匹配 |
| `assets[].width` / `height` | 可选正整数；提供时必须与实际图片像素尺寸一致 |
| `assets[].animated` | 可选布尔值，缺省 `false`；实际多帧图片必须声明为 `true`，单帧 GIF 仍为 `false` |

图片、文字的关联在同一个 asset 对象内明确表达：`id=happy-001 → path=assets/happy.png → name=开心`。不靠图片排序去猜另一份文字列表，不需要同名 TXT，也不读取 CSV/Excel 对照表。ID 必须唯一，路径按不区分大小写去重。写包工具统一输出上述 snake_case 字段。

带清单 ZIP 的普通文件集合必须恰好等于 `manifest.json` 加上全部 `assets[].path`。不能缺图，也不能多放 README、独立封面、独立缩略图或 macOS 元数据文件；目录条目本身不算资源文件。将缩略图声明成另一个 asset 会使它成为另一张表情，不会绑定成主图的预览。

### 8.3 缩略图、封面和标签

本机导入自动从每张主图生成最长边不超过 256px 的静态 PNG，等比缩放、不放大小图；动图取首帧。缩略图按主图关联并单独缓存，放大预览和发送继续使用校验后的完整图片或动图。无需随 ZIP 提供缩略图；当前清单没有 `thumbnail`、`thumbnail_path`、`cover` 或 `icon` 的导入字段。

对已核对原始素材的官方「明风 OvO」动图，软件显示随客户端内置的原始静态预览，避免动画稀疏开场导致空白；只有官方来源、表情 ID 和发送动图 SHA-256 均匹配时才使用，其他包及更新后的内容仍走自动生成。该显示例外不更改发送文件、清单和包版本。

商城的封面、面板图标和公开标签在创作中心选择或填写，个人标签只在本机保存。服务端生成商城派生图的尺寸与授权规则见 [免费商城方案](emoji-creator-store-plan.md#资源与版本)，目录字段见 [服务端 API](../../server/API.md#表情包导入投稿与审核)。这些展示资料与已有 Manifest 分离，ZIP 中自行添加字段不会完成上架，也不会授予官方或创作者权限。

### 8.4 导入限制与验证入口

归档最大 100 MiB，清单最大 1 MiB，单图最大 15 MiB，解压总量最大 300 MiB。静态图片每边最多 4096px，多帧图片每边最多 2048px；最多 500 帧，单图 `宽 × 高 × 帧数` 不超过 `100 × 1024 × 1024`。加密归档、链接、重复路径及超限压缩比会被拒绝。

对应实现为 [清单模型](../../client/lib/features/emoji/domain/emoji_pack_manifest.dart)、[导入器](../../client/lib/features/emoji/application/emoji_pack_importer.dart)、[图片校验](../../client/lib/features/emoji/application/emoji_pack_installer.dart) 与 [缩略图生成](../../client/lib/features/emoji/application/emoji_thumbnail.dart)。现有 [格式测试](../../client/test/features/emoji/emoji_pack_manifest_test.dart)、[安全测试](../../client/test/features/emoji/emoji_pack_importer_security_test.dart) 和 [图片 ZIP 导入测试](../../client/test/features/emoji/emoji_pack_import_flow_test.dart) 覆盖有效清单、对应资源、Hash/尺寸不匹配、额外文件、非法路径和普通 ZIP 自动清单。
