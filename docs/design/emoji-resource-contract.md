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

默认 `officialPackDownload=true`，`customPackImport=false`，分享与公开发布关闭。官方包复用现有发布资源，未新增商城、广场、私有云同步或社区功能。

删除安装只清理本机 Pack 目录；消息仍使用已有 `file_id` / `sticker_id` 展示。服务端通过现有 AutoMigrate 增加消息、回复可选身份列，新接口需要随服务端发布。

本次验证是自动化关键链路回归；仓库私聊开关关闭导致旧客户端私聊端到端测试跳过，不能据此宣称真机发送验收或生产部署完成。本地 Pack 依赖文件系统，当前以原生客户端为交付目标。
